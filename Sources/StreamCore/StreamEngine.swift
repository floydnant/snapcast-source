import AppKit
import CoreAudio
import Foundation
import Network
import SystemConfiguration

/// Owns the whole pipeline: discovery, connection, tap, conversion, reconnects.
///
/// Rules this enforces, each learned from a way the simpler setup failed:
///
/// - The tap only exists while the relay has accepted us. So "mute this Mac" only ever
///   means "because the audio is playing in the house" — a Mac is never silently muted
///   while its audio goes nowhere.
/// - Being replaced by another Mac is final until the user acts. Auto-reconnecting
///   would have two Macs take the stream from each other forever.
/// - Sleep tears everything down and wake rebuilds it, rather than trusting a socket
///   that was frozen for hours. A frozen socket is what wedged snapserver's tcp source.
/// - The tap is rebuilt whenever the output device or its format changes, and the
///   converter always produces 48 kHz, so the relay never sees a format change.
/// - A capture that delivers nothing is rebuilt once, then reported and stopped. Before
///   this, a Mac waiting on the capture-permission prompt reconnected every 4 seconds
///   indefinitely, toggling its own local mute each time.
/// - Backoff only resets after sustained healthy streaming, not on every accepted
///   connection, so no failure mode can retry at full speed forever.
///
/// All state is confined to one serial queue; callbacks arrive on `callbackQueue`.
public final class StreamEngine {
    public enum State: Equatable {
        case idle
        case searching
        case connecting(relay: String)
        case streaming(relay: String, since: Date)
        case replaced(by: String)
        case retrying(reason: String, at: Date)
        case failed(String)
        case sleeping
    }

    public enum RelayTarget: Equatable {
        case automatic
        case manual(host: String, port: UInt16)

        /// Parses "host", "host:port", "[v6]" or "[v6]:port". Empty means automatic.
        public init?(_ string: String) {
            let s = string.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { self = .automatic; return }
            var host = s
            var port = RelayProtocol.defaultPort
            if s.hasPrefix("[") {
                guard let close = s.firstIndex(of: "]") else { return nil }
                host = String(s[s.index(after: s.startIndex)..<close])
                let rest = s[s.index(after: close)...]
                if !rest.isEmpty {
                    guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) else { return nil }
                    port = p
                }
            } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
                host = String(s[..<colon])
                guard let p = UInt16(s[s.index(after: colon)...]) else { return nil }
                port = p
            }
            // Anything else with colons is a bare IPv6 address on the default port.
            guard !host.isEmpty, port > 0 else { return nil }
            self = .manual(host: host, port: port)
        }
    }

    public struct Configuration: Equatable {
        public var target: RelayTarget
        public var sourceName: String
        public var token: String?
        public var muteLocal: Bool
        /// Slider position, 0...1, before the volume curve.
        public var streamVolume: Float
        /// Also scale by the Mac's own output volume and mute (its volume keys).
        public var followSystemVolume: Bool

        public init(target: RelayTarget = .automatic, sourceName: String = StreamEngine.defaultSourceName,
                    token: String? = nil, muteLocal: Bool = true,
                    streamVolume: Float = 1, followSystemVolume: Bool = true) {
            self.target = target
            self.sourceName = sourceName
            self.token = token
            self.muteLocal = muteLocal
            self.streamVolume = streamVolume
            self.followSystemVolume = followSystemVolume
        }
    }

    public typealias CaptureFactory = (_ muteLocal: Bool, _ queue: DispatchQueue,
                                       _ onFormatChange: @escaping () -> Void) throws -> AudioCapture

    public static let systemTap: CaptureFactory = { mute, queue, onFormatChange in
        try SystemAudioTap(muteLocal: mute, queue: queue, onFormatChange: onFormatChange)
    }

    /// No capture callbacks for this long means the capture is stalled.
    static var captureStallTimeout: TimeInterval = 2
    /// Streaming this long without trouble resets the reconnect backoff.
    static var healthyStreamingDuration: TimeInterval = 10

    static let stallMessage = "This Mac isn't delivering any audio to capture. If macOS is asking for "
        + "permission to record system audio, allow it and start again; otherwise check System Settings "
        + "→ Privacy & Security → Screen & System Audio Recording."

    public struct Stats {
        public var sentBytes: Int
        public var droppedBytes: Int
        public var captureFormat: String?
    }

    public static var defaultSourceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    private let queue = DispatchQueue(label: "snapstream.engine", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    private let onStateChange: (State) -> Void
    private let onRelaysChange: ([RelayBrowser.Relay]) -> Void
    private let onOutputChange: (SystemVolumeWatcher.Info) -> Void
    private let makeCapture: CaptureFactory

    private var config: Configuration
    private var state: State = .idle
    private var wanted = false
    private var resumeAfterWake = false
    private var client: RelayClient?
    private var tap: AudioCapture?
    private var volumeWatcher: SystemVolumeWatcher?
    private let gain = GainControl()
    private let captureTicks = TickCounter()
    private var watchdog: DispatchSourceTimer?
    private var lastTicks = 0
    private var lastProgress = Date()
    private var streamingSince: Date?
    private var rebuiltForStall = false
    private var captureFormat: String?
    private var browser: RelayBrowser?
    private var discovered: [RelayBrowser.Relay] = []
    private var retryAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// One second of audio. Past that, oldest is dropped (see ByteRing).
    private let ring = ByteRing(capacity: Int(RelayProtocol.sampleRate) * RelayProtocol.bytesPerFrame)
    private let meter = LevelMeter()

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(configuration: Configuration, callbackQueue: DispatchQueue = .main,
                capture: @escaping CaptureFactory = StreamEngine.systemTap,
                onStateChange: @escaping (State) -> Void,
                onRelaysChange: @escaping ([RelayBrowser.Relay]) -> Void = { _ in },
                onOutputChange: @escaping (SystemVolumeWatcher.Info) -> Void = { _ in }) {
        self.config = configuration
        self.callbackQueue = callbackQueue
        self.makeCapture = capture
        self.onStateChange = onStateChange
        self.onRelaysChange = onRelaysChange
        self.onOutputChange = onOutputChange
        queue.async { self.setUp() }
    }

    // MARK: Public API (any thread)

    public func start() {
        queue.async {
            self.wanted = true
            self.retryAttempt = 0
            if self.client == nil { self.connect() }
        }
    }

    public func stop() {
        queue.async {
            self.wanted = false
            self.resumeAfterWake = false
            self.cancelRetry()
            self.teardown()
            self.set(.idle)
        }
    }

    public func update(_ configuration: Configuration) {
        queue.async {
            let old = self.config
            self.config = configuration
            guard old != configuration else { return }
            self.updateGain()
            guard self.wanted else { return }
            if old.target != configuration.target || old.sourceName != configuration.sourceName
                || old.token != configuration.token {
                self.teardown()
                self.connect()
            } else if old.muteLocal != configuration.muteLocal, self.tap != nil {
                self.rebuildTap()
            }
        }
    }

    /// Current input peak, 0...1. Cheap; poll it for a meter.
    public var level: Float { meter.value }

    public func stats() -> Stats {
        queue.sync { Stats(sentBytes: client?.sentBytes ?? 0, droppedBytes: ring.droppedBytes, captureFormat: captureFormat) }
    }

    /// Which Mac is streaming right now, according to the relay we would connect to.
    public func queryStatus(completion: @escaping (Result<RelayClient.StatusResult, Error>) -> Void) {
        queue.async {
            guard let (endpoint, _) = self.resolveTarget() else {
                struct NoRelay: LocalizedError { var errorDescription: String? { "No relay found." } }
                self.callbackQueue.async { completion(.failure(NoRelay())) }
                return
            }
            RelayClient.queryStatus(endpoint: endpoint, token: self.config.token, queue: self.queue) { result in
                self.callbackQueue.async { completion(result) }
            }
        }
    }

    // MARK: Lifecycle

    private func setUp() {
        let browser = RelayBrowser(queue: queue) { [weak self] relays in
            guard let self else { return }
            self.discovered = relays
            let cb = self.onRelaysChange
            self.callbackQueue.async { cb(relays) }
            if self.wanted, self.state == .searching { self.connect() }
        }
        browser.start()
        self.browser = browser

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            // Synchronous on purpose: the system may suspend us right after this returns,
            // and the tap must be gone (local audio unmuted) before that happens.
            self?.queue.sync { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            // Give WiFi a moment to rejoin before the first attempt.
            self?.queue.asyncAfter(deadline: .now() + 3) { self?.didWake() }
        })

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.tap != nil else { return }
            self.rebuildTap()
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)

        volumeWatcher = SystemVolumeWatcher(queue: queue) { [weak self] info in
            guard let self else { return }
            self.updateGain()
            let cb = self.onOutputChange
            self.callbackQueue.async { cb(info) }
        }
        updateGain()
    }

    private func updateGain() {
        var position = config.streamVolume
        if config.followSystemVolume, let info = volumeWatcher?.info {
            position *= info.factor
        }
        gain.value = VolumeCurve.gain(forPosition: position)
    }

    private func willSleep() {
        guard wanted else { return }
        resumeAfterWake = true
        cancelRetry()
        teardown()
        set(.sleeping)
    }

    private func didWake() {
        guard resumeAfterWake, wanted else { return }
        resumeAfterWake = false
        retryAttempt = 0
        connect()
    }

    // MARK: Connection

    private func resolveTarget() -> (NWEndpoint, String)? {
        switch config.target {
        case .manual(let host, let port):
            guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
            return (.hostPort(host: NWEndpoint.Host(host), port: p), "\(host):\(port)")
        case .automatic:
            guard let relay = discovered.first else { return nil }
            return (relay.endpoint, relay.name)
        }
    }

    private func connect() {
        guard wanted else { return }
        cancelRetry()
        guard let (endpoint, label) = resolveTarget() else {
            set(.searching)  // the browser calls connect() again when a relay appears
            return
        }
        generation += 1
        let gen = generation
        set(.connecting(relay: label))
        let hello = RelayProtocol.Hello(name: config.sourceName, token: config.token?.nilIfEmpty)
        let client = RelayClient(endpoint: endpoint, hello: hello, ring: ring, queue: queue) { [weak self] event in
            self?.handle(event, generation: gen, relay: label)
        }
        self.client = client
        client.start()
    }

    private func handle(_ event: RelayClient.Event, generation gen: Int, relay: String) {
        guard gen == generation else { return }  // from a client we already tore down
        switch event {
        case .welcome:
            do {
                try startTap()
                rebuiltForStall = false
                streamingSince = Date()
                startWatchdog()
                set(.streaming(relay: relay, since: Date()))
            } catch {
                teardown()
                wanted = false
                set(.failed(error.localizedDescription))
            }
        case .replaced(let by):
            teardown()
            wanted = false
            set(.replaced(by: by))
        case .relayHeardNothing:
            let captureHealthy = tap != nil && Date().timeIntervalSince(lastProgress) < 1
            teardown()
            if captureHealthy {
                scheduleRetry(reason: "The connection stalled.")  // network, and it recovered
            } else {
                wanted = false
                set(.failed(Self.stallMessage))
            }
        case .refused(let reason):
            teardown()
            wanted = false
            set(.failed(reason))
        case .failed(let reason):
            teardown()
            scheduleRetry(reason: reason)
        }
    }

    private func scheduleRetry(reason: String) {
        guard wanted else { set(.idle); return }
        let delay = min(10, pow(2, Double(retryAttempt)))  // 1, 2, 4, 8, 10, 10...
        retryAttempt += 1
        set(.retrying(reason: reason, at: Date().addingTimeInterval(delay)))
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
    }

    private func teardown() {
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        streamingSince = nil
        tap?.stop()
        tap = nil
        captureFormat = nil
        meter.value = 0
        client?.cancel()
        client = nil
    }

    // MARK: Tap

    private func startTap() throws {
        let tap = try makeCapture(config.muteLocal, queue) { [weak self] in
            guard let self, self.tap != nil else { return }
            self.rebuildTap()
        }
        let converter = try PCMConverter(input: tap.format, gain: gain)
        let ring = self.ring
        let meter = self.meter
        let ticks = captureTicks
        lastProgress = Date()
        lastTicks = ticks.value
        try tap.start { list in
            ticks.increment()
            converter.convert(list) { bytes, count in ring.write(bytes, count) }
            meter.value = converter.peak
        }
        self.tap = tap
        captureFormat = "\(Int(tap.format.sampleRate)) Hz, \(tap.format.channelCount) ch"
    }

    private func rebuildTap() {
        tap?.stop()
        tap = nil
        do {
            try startTap()
        } catch {
            teardown()
            wanted = false
            set(.failed(error.localizedDescription))
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkCapture() }
        timer.resume()
        watchdog = timer
    }

    private func checkCapture() {
        guard tap != nil else { return }
        let now = Date()
        let ticks = captureTicks.value
        if ticks != lastTicks {
            lastTicks = ticks
            lastProgress = now
            if let since = streamingSince, now.timeIntervalSince(since) > Self.healthyStreamingDuration {
                retryAttempt = 0
                rebuiltForStall = false
            }
            return
        }
        guard now.timeIntervalSince(lastProgress) > Self.captureStallTimeout else { return }
        if !rebuiltForStall {
            rebuiltForStall = true
            rebuildTap()  // one fresh tap first: device changes can leave an old one dead
        } else {
            teardown()
            wanted = false
            set(.failed(Self.stallMessage))
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        let cb = onStateChange
        callbackQueue.async { cb(new) }
    }
}

/// Incremented on the audio thread, read by the watchdog.
final class TickCounter {
    private var lock = os_unfair_lock()
    private var _value = 0
    var value: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _value }
    func increment() { os_unfair_lock_lock(&lock); _value &+= 1; os_unfair_lock_unlock(&lock) }
}

/// Written on the audio thread, read by the UI.
final class LevelMeter {
    private var lock = os_unfair_lock()
    private var _value: Float = 0
    var value: Float {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _value }
        set { os_unfair_lock_lock(&lock); _value = newValue; os_unfair_lock_unlock(&lock) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
