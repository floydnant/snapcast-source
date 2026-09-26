import AVFoundation
import Network
import XCTest
@testable import StreamCore

/// Speaks just enough of the relay protocol: accepts, welcomes, pings, counts audio.
final class FakeRelay {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake-relay")
    private let lock = NSLock()
    private var _connections = 0
    private var _audioBytes = 0
    private var conns: [NWConnection] = []
    var port: UInt16 { listener.port!.rawValue }

    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    var audioBytes: Int { lock.lock(); defer { lock.unlock() }; return _audioBytes }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel(); conns.forEach { $0.cancel() } }

    private func accept(_ c: NWConnection) {
        lock.lock(); _connections += 1; lock.unlock()
        conns.append(c)
        c.start(queue: queue)
        var buffer = Data()
        var welcomed = false
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
                guard let self else { return }
                if let data { buffer.append(data) }
                if !welcomed, let nl = buffer.firstIndex(of: 0x0A) {
                    welcomed = true
                    buffer.removeSubrange(buffer.startIndex...nl)
                    self.send(c, #"{"type":"welcome","format":"48000:16:2"}"#)
                    self.ping(c)
                }
                if welcomed {
                    self.lock.lock(); self._audioBytes += buffer.count; self.lock.unlock()
                    buffer.removeAll()
                }
                if !done { receive() }
            }
        }
        receive()
    }

    func send(_ c: NWConnection, _ line: String) {
        c.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func ping(_ c: NWConnection) {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, c.state == .ready else { return }
            self.send(c, #"{"type":"ping"}"#)
            self.ping(c)
        }
    }

    func replaceAll(by name: String) {
        queue.async { self.conns.forEach { self.send($0, #"{"type":"replaced","by":"\#(name)"}"#) } }
    }
}

/// A capture that either delivers a steady tone or, like a tap waiting on the
/// permission prompt, never calls back at all.
final class FakeCapture: AudioCapture {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let deliver: Bool
    private var timer: DispatchSourceTimer?
    init(deliver: Bool) { self.deliver = deliver }

    func start(_ handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        guard deliver else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for c in 0..<2 { for i in 0..<480 { buffer.floatChannelData![c][i] = 0.25 } }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake-capture"))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { handler(buffer.audioBufferList) }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}

final class EngineTests: XCTestCase {
    private var states: [StreamEngine.State] = []
    private let lock = NSLock()

    override func setUp() {
        StreamEngine.captureStallTimeout = 0.3
        states = []
    }

    private func engine(relay: FakeRelay, deliver: Bool) -> StreamEngine {
        let config = StreamEngine.Configuration(target: .manual(host: "127.0.0.1", port: relay.port),
                                                sourceName: "Test Mac", muteLocal: false)
        return StreamEngine(configuration: config, callbackQueue: DispatchQueue(label: "cb"),
                            capture: { _, _, _ in FakeCapture(deliver: deliver) },
                            onStateChange: { [weak self] s in
                                self?.lock.lock(); self?.states.append(s); self?.lock.unlock()
                            })
    }

    private func current() -> StreamEngine.State? { lock.lock(); defer { lock.unlock() }; return states.last }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what); states: \(states)")
    }

    func testHealthyCaptureStreamsAudio() throws {
        let relay = try FakeRelay()
        let e = engine(relay: relay, deliver: true)
        e.start()
        waitFor("streaming") { if case .streaming? = current() { return true }; return false }
        waitFor("audio at the relay") { relay.audioBytes > 48_000 }
        e.stop()
    }

    /// The failure seen in production: the relay accepts, the capture never delivers.
    func testStalledCaptureStopsOnceInsteadOfLooping() throws {
        let relay = try FakeRelay()
        let e = engine(relay: relay, deliver: false)
        e.start()
        waitFor("failed") { if case .failed? = current() { return true }; return false }
        XCTAssertEqual(current(), .failed(StreamEngine.stallMessage))
        Thread.sleep(forTimeInterval: 1.5)  // longer than any retry backoff would be
        XCTAssertEqual(relay.connections, 1, "a stalled capture must not reconnect")
        XCTAssertEqual(relay.audioBytes, 0)
    }

    func testReplacedIsFinal() throws {
        let relay = try FakeRelay()
        let e = engine(relay: relay, deliver: true)
        e.start()
        waitFor("streaming") { if case .streaming? = current() { return true }; return false }
        relay.replaceAll(by: "Mac B")
        waitFor("replaced") { current() == .replaced(by: "Mac B") }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(relay.connections, 1, "being replaced must not trigger a reconnect")
    }
}

final class VolumeTests: XCTestCase {
    func testCurveEndpointsAndShape() {
        XCTAssertEqual(VolumeCurve.gain(forPosition: 0), 0)
        XCTAssertEqual(VolumeCurve.gain(forPosition: 1), 1)
        XCTAssertEqual(VolumeCurve.gain(forPosition: 0.5), 0.125, accuracy: 1e-6)
        XCTAssertEqual(VolumeCurve.gain(forPosition: 2), 1, "out of range clamps")
    }

    /// Gain applies, and a change ramps across the next buffer rather than stepping.
    func testGainAppliesAndRamps() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let gain = GainControl(1)
        let converter = try PCMConverter(input: format, gain: gain)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        for c in 0..<2 { for i in 0..<512 { buffer.floatChannelData![c][i] = 0.5 } }

        func run() -> [Int16] {
            var out: [Int16] = []
            converter.convert(buffer.audioBufferList) { p, n in
                out = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Int16.self), count: n / 2))
            }
            return out
        }
        for _ in 0..<4 { _ = run() }  // settle the converter
        let full = Double(run().last!)
        gain.value = 0.25
        let ramp = run()
        XCTAssertEqual(Double(ramp.first!) / full, 1, accuracy: 0.02, "first sample should still be near the old gain")
        XCTAssertEqual(Double(ramp.last!) / full, 0.25, accuracy: 0.02, "last sample should reach the new gain")
        XCTAssertEqual(Double(run().last!) / full, 0.25, accuracy: 0.02)
        XCTAssertEqual(converter.peak, 0.125, accuracy: 0.01, "meter shows the level as sent")
    }
}

final class SnapcastControlTests: XCTestCase {
    func testParsesStatus() throws {
        let json = """
        {"server":{"groups":[
          {"id":"g1","stream_id":"Mac","clients":[
            {"id":"a","connected":true,"config":{"name":"Kitchen","volume":{"percent":46,"muted":false}},"host":{"name":"pi-a"}},
            {"id":"b","connected":false,"config":{"name":"","volume":{"percent":100,"muted":true}},"host":{"name":"pi-b"}}]},
          {"id":"g2","stream_id":"AirPlay","clients":[
            {"id":"c","connected":true,"config":{"name":"Bathroom","volume":{"percent":80,"muted":true}},"host":{"name":"pi-c"}}]}],
         "streams":[{"id":"Mac","status":"playing"},{"id":"AirPlay","status":"idle"}]}}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let snap = SnapcastControl.parse(status: obj)
        XCTAssertEqual(snap.speakers.map(\.name), ["Bathroom", "Kitchen", "pi-b"], "sorted; host name when unnamed")
        XCTAssertEqual(snap.speakers.first { $0.id == "a" },
                       .init(id: "a", name: "Kitchen", connected: true, percent: 46, muted: false, groupID: "g1", streamID: "Mac"))
        XCTAssertEqual(snap.speakers.first { $0.id == "c" }?.streamID, "AirPlay")
        XCTAssertEqual(snap.streams, ["Mac": "playing", "AirPlay": "idle"])
    }

    func testLineSplitter() throws {
        var s = LineSplitter()
        XCTAssertEqual(try s.feed(Data("ab".utf8)), [])
        XCTAssertEqual(try s.feed(Data("c\n\nde\nf".utf8)), [Data("abc".utf8), Data("de".utf8)])
        XCTAssertEqual(try s.feed(Data("\n".utf8)), [Data("f".utf8)])
    }
}
