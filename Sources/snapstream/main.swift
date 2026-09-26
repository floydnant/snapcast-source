// snapstream — headless front end to the same pipeline the menu bar app uses.
//
//   snapstream tap-test [--seconds N] [--mute]     capture + convert only, report rates
//   snapstream browse [--seconds N]                list relays found over Bonjour
//   snapstream status [--relay HOST[:PORT]]        which Mac is streaming right now
//   snapstream stream [--relay HOST[:PORT]] [--name NAME] [--no-mute] [--seconds N]
//
// `--relay` defaults to $SNAPSTREAM_RELAY, then to automatic discovery.

import Foundation
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
            case .success(let s):
                print(s.active.map { "active: \($0) since \(Date(timeIntervalSince1970: TimeInterval(s.since ?? 0)))" } ?? "active: nobody")
                exit(0)
            case .failure(let e):
                die(e.localizedDescription)
            }
        }
    }
    dispatchMain()

case "stream":
    var config = StreamEngine.Configuration(target: target, token: token, muteLocal: !flag("--no-mute"))
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

default:
    print("""
    usage:
      snapstream tap-test [--seconds N] [--mute]
      snapstream browse [--seconds N]
      snapstream status [--relay HOST[:PORT]]
      snapstream stream [--relay HOST[:PORT]] [--name NAME] [--no-mute] [--seconds N]
    """)
    exit(command == "help" ? 0 : 1)
}
