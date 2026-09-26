// snapstream — headless front end to the same pipeline the menu bar app uses.
//
//   snapstream tap-test [--seconds N] [--mute]     capture + convert only, report rates
//   snapstream browse [--seconds N]                list relays found over Bonjour
//   snapstream status [--relay HOST[:PORT]]        which Mac is streaming right now
//   snapstream stream [--relay HOST[:PORT]] [--name NAME] [--no-mute] [--volume 0-1] [--seconds N]
//   snapstream speakers [--relay HOST[:PORT]]      speakers, via snapserver's control port
//   snapstream speaker-volume ID PERCENT [--mute | --unmute] [--relay HOST[:PORT]]
//
// `--relay` defaults to $SNAPSTREAM_RELAY, then to automatic discovery.

import Foundation
import Network
import StreamCore

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
func die(_ message: String) -> Never {
    FileHandle.standardError.write(("snapstream: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let seconds = option("--seconds").flatMap(Double.init)
let relayArg = option("--relay") ?? ProcessInfo.processInfo.environment["SNAPSTREAM_RELAY"] ?? ""
guard let target = StreamEngine.RelayTarget(relayArg) else { die("bad --relay: \(relayArg)") }
let token = option("--token") ?? ProcessInfo.processInfo.environment["SNAPSRC_TOKEN"]

/// Stop cleanly on Ctrl-C, so a muting tap is always destroyed and local audio returns.
func onInterrupt(_ handler: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        interruptSources.append(source)
    }
}
var interruptSources: [DispatchSourceSignal] = []
var verifiers: [SnapcastControl] = []
var controlHost: NWEndpoint.Host?
var controlPort: UInt16?

func describe(_ state: StreamEngine.State) -> String {
    switch state {
    case .idle: return "idle"
    case .searching: return "searching for a relay"
    case .connecting(let r): return "connecting to \(r)"
    case .streaming(let r, _): return "streaming to \(r)"
    case .replaced(let by): return "replaced by \(by)"
    case .retrying(let reason, let at): return "retrying in \(max(0, Int(at.timeIntervalSinceNow.rounded())))s: \(reason)"
    case .failed(let reason): return "failed: \(reason)"
    case .sleeping: return "sleeping"
    }
}

switch command {
case "tap-test":
    let queue = DispatchQueue(label: "tap-test")
    let tap: SystemAudioTap
    let converter: PCMConverter
    do {
        tap = try SystemAudioTap(muteLocal: flag("--mute"), queue: queue) { print("tap format changed") }
        converter = try PCMConverter(input: tap.format)
    } catch { die(error.localizedDescription) }
    print("tap: \(tap.format)")
    print("out: \(converter.output)")
    let ring = ByteRing(capacity: 48_000 * 4 * 30)
    var peak: Float = 0
    let lock = NSLock()
    let started = Date()
    do {
        try tap.start { list in
            converter.convert(list) { p, n in ring.write(p, n) }
            lock.lock(); peak = max(peak, converter.peak); lock.unlock()
        }
    } catch { die(error.localizedDescription) }
    let duration = seconds ?? 5
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        tap.stop()
        let wall = Date().timeIntervalSince(started)
        let frames = ring.available / 4
        lock.lock(); let p = peak; lock.unlock()
        print(String(format: "wall %.2fs  out %d frames = %.0f frames/s (target 48000)  peak %.3f%@",
                     wall, frames, Double(frames) / wall, p, p == 0 ? "  (silence: is anything playing?)" : ""))
        exit(0)
    }
    onInterrupt { tap.stop(); exit(0) }
    dispatchMain()

case "browse":
    let browser = RelayBrowser(queue: .main) { relays in
        print(relays.isEmpty ? "(no relays)" : relays.map { "\($0.name)  \($0.endpoint)" }.joined(separator: "\n"))
    }
    browser.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + (seconds ?? 3)) { exit(0) }
    dispatchMain()

case "status":
    let engine = StreamEngine(configuration: .init(target: target, token: token), onStateChange: { _ in })
    // Automatic discovery needs a moment to find the relay first.
    DispatchQueue.main.asyncAfter(deadline: .now() + (target == .automatic ? 2 : 0)) {
        engine.queryStatus { result in
            switch result {
            case .success(let r):
                let s = r.status
                print(s.active.map { "active: \($0) since \(Date(timeIntervalSince1970: TimeInterval(s.since ?? 0)))" } ?? "active: nobody")
                print("control: \(s.control.map { "port \($0)" } ?? "not advertised (relay predates speaker controls)")"
                    + (r.host.map { " on \($0)" } ?? ""))
                exit(0)
            case .failure(let e):
                die(e.localizedDescription)
            }
        }
    }
    dispatchMain()

case "stream":
    var config = StreamEngine.Configuration(target: target, token: token, muteLocal: !flag("--no-mute"))
    if let v = option("--volume").flatMap(Float.init) { config.streamVolume = v }
    if let name = option("--name") { config.sourceName = name }
    let engine = StreamEngine(configuration: config, onStateChange: { print("state: \(describe($0))") })
    engine.start()
    var lastSent = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler {
        let s = engine.stats()
        print(String(format: "  sent %6.1f KB/s  dropped %d B  level %.3f  capture %@",
                     Double(s.sentBytes - lastSent) / 2048, s.droppedBytes, engine.level, s.captureFormat ?? "-"))
        lastSent = s.sentBytes
    }
    timer.resume()
    func finish() {
        engine.stop()
        // Let the engine queue tear the tap down (unmuting) before exiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
    if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() } }
    onInterrupt { finish() }
    dispatchMain()

case "speakers", "speaker-volume":
    // Resolve the relay, ask it for snapserver's control port, then talk to snapserver.
    let engine = StreamEngine(configuration: .init(target: target, token: token), onStateChange: { _ in })
    var control: SnapcastControl!
    var acted = false
    control = SnapcastControl(onSnapshot: { snap in
        if command == "speakers" {
            for sp in snap.speakers {
                let name = sp.name.padding(toLength: max(sp.name.count, 16), withPad: " ", startingAt: 0)
                let volume = "\(sp.percent)%".padding(toLength: 5, withPad: " ", startingAt: 0)
                print("\(name) \(volume)\(sp.muted ? "muted" : "     ")  stream=\(sp.streamID)"
                      + "\(sp.connected ? "" : "  (disconnected)")  id=\(sp.id)")
            }
            print("streams: " + snap.streams.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            exit(0)
        }
        // speaker-volume: act once on the first snapshot, then report the next one.
        let id = args.count > 0 ? args[0] : ""
        guard let sp = snap.speakers.first(where: { $0.id == id }) else { die("no speaker with id \(id)") }
        if !acted {
            acted = true
            guard args.count > 1, let pct = Int(args[1]) else { die("usage: speaker-volume ID PERCENT") }
            control.setVolume(id, percent: pct)
            if flag("--mute") { control.setMuted(id, true) }
            if flag("--unmute") { control.setMuted(id, false) }
            // Re-read from the server to prove the change landed, not just the optimistic copy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                control.disconnect()
                let verify = SnapcastControl(onSnapshot: { s in
                    if let v = s.speakers.first(where: { $0.id == id }) {
                        print("\(v.name): server now reports \(v.percent)%\(v.muted ? " muted" : "")")
                        exit(0)
                    }
                })
                verifiers.append(verify)
                verify.connect(host: controlHost!, port: controlPort!)
            }
        } else {
            _ = sp
        }
    }, onState: { state in
        if case .failed(let reason) = state { die(reason) }
    })
    DispatchQueue.main.asyncAfter(deadline: .now() + (target == .automatic ? 2 : 0)) {
        engine.queryStatus { result in
            switch result {
            case .success(let r):
                guard let port = r.status.control, port > 0, let host = r.host else {
                    die("relay does not advertise snapserver's control port")
                }
                controlHost = host
                controlPort = UInt16(port)
                control.connect(host: host, port: UInt16(port))
            case .failure(let e):
                die(e.localizedDescription)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { die("timed out") }
    dispatchMain()

default:
    print("""
    usage:
      snapstream tap-test [--seconds N] [--mute]
      snapstream browse [--seconds N]
      snapstream status [--relay HOST[:PORT]]
      snapstream stream [--relay HOST[:PORT]] [--name NAME] [--no-mute] [--volume 0-1] [--seconds N]
      snapstream speakers [--relay HOST[:PORT]]
      snapstream speaker-volume ID PERCENT [--mute | --unmute] [--relay HOST[:PORT]]
    """)
    exit(command == "help" ? 0 : 1)
}
