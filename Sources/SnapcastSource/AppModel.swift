import AppKit
import Combine
import ServiceManagement
import StreamCore

/// UI state and settings. The engine does the work; this translates it for the menu.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: StreamEngine.State = .idle
    @Published private(set) var relays: [RelayBrowser.Relay] = []
    @Published private(set) var level: Float = 0
    /// Another Mac holding the stream, per the relay's status. Shown so you know what
    /// pressing Start will do before you press it.
    @Published private(set) var activeElsewhere: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginItemError: String?

    @Published var relayOverride: String { didSet { save(); pushConfig() } }
    @Published var muteLocal: Bool { didSet { save(); pushConfig() } }
    @Published var sourceName: String { didSet { save(); pushConfig() } }
    @Published var token: String { didSet { save(); pushConfig() } }
    @Published var streamOnLaunch: Bool { didSet { save() } }

    private var engine: StreamEngine!
    private var levelTimer: Timer?
    private var statusTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        relayOverride = defaults.string(forKey: "relayOverride") ?? ""
        muteLocal = defaults.object(forKey: "muteLocal") as? Bool ?? true
        sourceName = defaults.string(forKey: "sourceName") ?? ""
        token = defaults.string(forKey: "token") ?? ""
        streamOnLaunch = defaults.bool(forKey: "streamOnLaunch")

        engine = StreamEngine(
            configuration: configuration(),
            onStateChange: { [weak self] in self?.stateChanged($0) },
            onRelaysChange: { [weak self] in self?.relays = $0 })

        // Scheduled on the main run loop, so the callbacks are already on the main actor.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStatus() }
        }
        if streamOnLaunch { engine.start() }
    }

    // MARK: Derived

    var isActive: Bool {
        switch state {
        case .idle, .replaced, .failed: return false
        default: return true
        }
    }

    var isStreaming: Bool {
        if case .streaming = state { return true }
        return false
    }

    var effectiveSourceName: String { sourceName.isEmpty ? StreamEngine.defaultSourceName : sourceName }
    var relayOverrideIsValid: Bool { StreamEngine.RelayTarget(relayOverride) != nil }

    var menuBarSymbol: String {
        switch state {
        case .streaming: return "hifispeaker.fill"
        case .connecting, .searching, .retrying, .sleeping: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .idle, .replaced: return "hifispeaker"
        }
    }

    var headline: String {
        switch state {
        case .idle: return activeElsewhere.map { "\($0) is streaming" } ?? "Not streaming"
        case .searching: return "Looking for a relay…"
        case .connecting(let relay): return "Connecting to \(relay)…"
        case .streaming(let relay, _): return "Streaming to \(relay)"
        case .replaced(let by): return "\(by) took over"
        case .retrying: return "Reconnecting…"
        case .failed: return "Stopped"
        case .sleeping: return "Paused while asleep"
        }
    }

    var detail: String? {
        switch state {
        case .retrying(let reason, _), .failed(let reason): return reason
        case .streaming:
            return muteLocal ? "This Mac is muted while streaming." : "Also playing on this Mac."
        case .replaced: return "Start again to take the stream back."
        case .searching: return "No relay found on this network. Set one manually below."
        default: return nil
        }
    }

    var primaryActionTitle: String {
        if isActive { return "Stop Streaming" }
        return activeElsewhere != nil || { if case .replaced = state { return true }; return false }()
            ? "Take Over" : "Start Streaming"
    }

    // MARK: Actions

    func primaryAction() {
        if isActive {
            engine.stop()
        } else {
            activeElsewhere = nil
            engine.start()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        engine.stop()
        // Give the engine a moment to destroy the tap, so a muted Mac is unmuted before
        // the process goes away. (It would unmute on exit anyway: the tap is private.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: Plumbing

    private func configuration() -> StreamEngine.Configuration {
        StreamEngine.Configuration(
            target: StreamEngine.RelayTarget(relayOverride) ?? .automatic,
            sourceName: effectiveSourceName,
            token: token.isEmpty ? nil : token,
            muteLocal: muteLocal)
    }

    private func pushConfig() {
        guard engine != nil else { return }
        engine.update(configuration())
    }

    private func save() {
        defaults.set(relayOverride, forKey: "relayOverride")
        defaults.set(muteLocal, forKey: "muteLocal")
        defaults.set(sourceName, forKey: "sourceName")
        defaults.set(token, forKey: "token")
        defaults.set(streamOnLaunch, forKey: "streamOnLaunch")
    }

    private func stateChanged(_ new: StreamEngine.State) {
        state = new
        if case .streaming = new {
            activeElsewhere = nil
            startLevelTimer()
        } else {
            stopLevelTimer()
        }
    }

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Fast attack, slow release, so the meter reads as a meter.
                let target = self.engine.level
                self.level = target > self.level ? target : self.level * 0.8 + target * 0.2
            }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }

    private func pollStatus() {
        guard !isActive else { return }
        engine.queryStatus { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isActive else { return }
                if case .success(let status) = result, let active = status.active, active != self.effectiveSourceName {
                    self.activeElsewhere = active
                } else {
                    self.activeElsewhere = nil
                }
            }
        }
    }
}
