import Foundation
import Network

/// One streaming session with a relay. Not reusable: make a new one to reconnect.
///
/// Liveness is checked in both directions without any extra traffic from us: the audio
/// itself proves we are alive to the relay (it drops a source that goes quiet for 3s),
/// and the relay's once-a-second ping proves it is alive to us. Missing pings mean the
/// relay or the network is gone, and we fail fast instead of writing into a void.
public final class RelayClient {
    public enum Event: Equatable {
        case welcome
        case replaced(by: String)
        /// The relay dropped us for sending no audio on a connection that stayed up.
        /// Either our capture stalled, or the network did and has recovered; only the
        /// engine knows which.
        case relayHeardNothing
        case refused(String)
        case failed(String)
    }

    public struct StatusResult {
        public var status: RelayProtocol.Control
        /// The relay's address as actually connected to, e.g. resolved from Bonjour.
        public var host: NWEndpoint.Host?
    }

    public static let pingTimeout: TimeInterval = 3
    /// Upper bound per send. The next send is only issued when the previous one has been
    /// accepted by the stack, so TCP backpressure lands in the ByteRing (which drops
    /// oldest) instead of growing an unbounded queue of pending sends.
    static let maxSendBytes = 19_200  // 100 ms

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let hello: RelayProtocol.Hello
    private let ring: ByteRing
    private let onEvent: (Event) -> Void

    private var parser = ControlLineParser()
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?
    private var finished = false
    private var welcomed = false

    public private(set) var sentBytes = 0

    public init(endpoint: NWEndpoint, hello: RelayProtocol.Hello, ring: ByteRing,
                queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.connection = NWConnection(to: endpoint, using: Self.parameters())
        self.queue = queue
        self.hello = hello
        self.ring = ring
        self.onEvent = onEvent
    }

    static func parameters(ipv4Only: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        if ipv4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return params
    }

    /// Must be called on `queue`.
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
        lastHeard = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if Date().timeIntervalSince(self.lastHeard) > Self.pingTimeout {
                self.finish(.failed(self.welcomed ? "Relay stopped responding." : "Relay did not answer."))
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// User-initiated close; emits no event. Must be called on `queue`.
    public func cancel() { finish(nil) }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(hello: hello)
            receive()
        case .waiting(let error):
            // NWConnection would sit here retrying on its own schedule; the engine's
            // backoff is more predictable and shows up in the UI.
            finish(.failed(Self.describe(error)))
        case .failed(let error):
            finish(.failed(Self.describe(error)))
        default:
            break
        }
    }

    private func send(hello: RelayProtocol.Hello) {
        guard let data = try? hello.encoded() else {
            finish(.failed("Could not encode hello."))
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failed(Self.describe(error))) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.parser.feed(data) {
                        self.handle(message)
                        if self.finished { return }
                    }
                } catch {
                    self.finish(.failed("Relay sent something unexpected."))
                    return
                }
            }
            if let error {
                self.finish(.failed(Self.describe(error)))
            } else if isComplete {
                self.finish(.failed("Relay closed the connection."))
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ message: RelayProtocol.Control) {
        lastHeard = Date()
        switch message.type {
        case "welcome":
            guard !welcomed else { return }
            welcomed = true
            ring.reset()  // never send audio captured before the relay accepted us
            onEvent(.welcome)
            pump()
        case "ping":
            break
        case "replaced":
            finish(.replaced(by: message.by ?? "another Mac"))
        case "error" where message.code == RelayProtocol.noAudioCode:
            finish(.relayHeardNothing)
        case "error":
            finish(.refused(message.reason ?? "Relay refused the connection."))
        default:
            break  // forward compatible: ignore unknown control messages
        }
    }

    private func pump() {
        guard !finished else { return }
        guard let chunk = ring.read(maxLength: Self.maxSendBytes) else {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.pump() }
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failed(Self.describe(error)))
            } else {
                self.sentBytes += chunk.count
                self.pump()
            }
        })
    }

    private func finish(_ event: Event?) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let event { onEvent(event) }
    }

    static func describe(_ error: Error, service: String = "Relay") -> String {
        if let nw = error as? NWError {
            switch nw {
            case .posix(.ECONNREFUSED): return "\(service) is not running (connection refused)."
            case .posix(.ETIMEDOUT): return "\(service) did not answer (timed out)."
            case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH): return "\(service) is unreachable."
            case .dns: return "\(service) host name could not be resolved."
            default: return nw.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Status query

    /// Asks a relay which source is currently streaming, without disturbing it.
    ///
    /// Tries IPv4 first. The host this resolves to is also where the app reaches
    /// snapserver's control port, and snapserver listens on IPv4 only by default; over
    /// Bonjour, the relay (which listens dual-stack) otherwise tends to resolve to IPv6.
    public static func queryStatus(endpoint: NWEndpoint, token: String?, queue: DispatchQueue,
                                   completion: @escaping (Result<StatusResult, Error>) -> Void) {
        queryStatusOnce(endpoint: endpoint, token: token, queue: queue, ipv4Only: true) { result in
            if case .failure = result {
                queryStatusOnce(endpoint: endpoint, token: token, queue: queue, ipv4Only: false, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    private static func queryStatusOnce(endpoint: NWEndpoint, token: String?, queue: DispatchQueue, ipv4Only: Bool,
                                        completion: @escaping (Result<StatusResult, Error>) -> Void) {
        struct QueryError: LocalizedError { let errorDescription: String? }
        let connection = NWConnection(to: endpoint, using: parameters(ipv4Only: ipv4Only))
        var parser = ControlLineParser()
        var done = false
        func complete(_ result: Result<StatusResult, Error>) {
            guard !done else { return }
            done = true
            connection.cancel()
            completion(result)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data, let messages = try? parser.feed(data), let first = messages.first {
                    if first.type == "error" {
                        complete(.failure(QueryError(errorDescription: first.reason)))
                    } else {
                        var host: NWEndpoint.Host?
                        if case .hostPort(let h, _)? = connection.currentPath?.remoteEndpoint { host = h }
                        complete(.success(StatusResult(status: first, host: host)))
                    }
                } else if let error {
                    complete(.failure(error))
                } else if isComplete {
                    complete(.failure(QueryError(errorDescription: "Relay closed without answering.")))
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let hello = RelayProtocol.Hello(mode: "status", name: "", format: nil, token: token)
                connection.send(content: try? hello.encoded(), completion: .contentProcessed { _ in })
                receive()
            case .waiting(let error), .failed(let error):
                complete(.failure(QueryError(errorDescription: describe(error))))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) {
            complete(.failure(QueryError(errorDescription: "Relay did not answer.")))
        }
    }
}
