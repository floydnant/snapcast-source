import Foundation
import Network

/// Speaker volume and mute, via snapserver's own JSON-RPC control API (the same one
/// Snapweb uses). The address comes from the relay's status, so nothing is configured.
///
/// Volume changes are coalesced per speaker: while one Client.SetVolume is in flight,
/// newer values from a dragged slider just replace the pending one. That keeps a slider
/// drag from queueing hundreds of requests, without a timer-based throttle that would
/// drop the final position.
public final class SnapcastControl {
    public struct Speaker: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var connected: Bool
        public var percent: Int
        public var muted: Bool
        public var groupID: String
        public var streamID: String
    }

    public struct Snapshot: Equatable {
        public var speakers: [Speaker] = []
        /// stream id -> "playing" / "idle"
        public var streams: [String: String] = [:]
    }

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private let queue = DispatchQueue(label: "snapcast.control")
    private let callbackQueue: DispatchQueue
    private let onSnapshot: (Snapshot) -> Void
    private let onState: (ConnectionState) -> Void

    private var target: (host: NWEndpoint.Host, port: UInt16)?
    private var connection: NWConnection?
    private var splitter = LineSplitter()
    private var nextID = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var snapshot = Snapshot()
    private var refreshScheduled = false
    private var reconnectWork: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 1
    /// Per speaker: desired (percent, muted) not yet sent, and whether a send is in flight.
    private var wantedVolume: [String: (Int, Bool)] = [:]
    private var volumeInFlight: Set<String> = []

    public init(callbackQueue: DispatchQueue = .main,
                onSnapshot: @escaping (Snapshot) -> Void,
                onState: @escaping (ConnectionState) -> Void = { _ in }) {
        self.callbackQueue = callbackQueue
        self.onSnapshot = onSnapshot
        self.onState = onState
    }

    /// Connects, or does nothing if already pointed at this address.
    public func connect(host: NWEndpoint.Host, port: UInt16) {
        queue.async {
            if let t = self.target, t.host == host, t.port == port, self.connection != nil { return }
            self.target = (host, port)
            self.reconnectDelay = 1
            self.open()
        }
    }

    public func disconnect() {
        queue.async {
            self.target = nil
            self.close()
            self.publish(state: .disconnected)
        }
    }

    public func setVolume(_ speakerID: String, percent: Int) {
        queue.async { self.change(speakerID) { $0.percent = max(0, min(100, percent)) } }
    }

    public func setMuted(_ speakerID: String, _ muted: Bool) {
        queue.async { self.change(speakerID) { $0.muted = muted } }
    }

    // MARK: Connection

    private func open() {
        close()
        guard let target, let port = NWEndpoint.Port(rawValue: target.port) else { return }
        publish(state: .connecting)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let c = NWConnection(host: target.host, port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                self.reconnectDelay = 1
                self.publish(state: .connected)
                self.receive(on: c)
                self.refresh()
            case .waiting(let e), .failed(let e):
                self.fail(RelayClient.describe(e, service: "Snapserver's control port"))
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func close() {
        reconnectWork?.cancel()
        reconnectWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        splitter = LineSplitter()
        let callbacks = pending.values
        pending = [:]
        volumeInFlight = []
        struct Closed: LocalizedError { var errorDescription: String? { "Connection closed." } }
        callbacks.forEach { $0(.failure(Closed())) }
    }

    private func fail(_ reason: String) {
        close()
        publish(state: .failed(reason))
        guard target != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
        reconnectDelay = min(10, reconnectDelay * 2)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, c === self.connection else { return }
            if let data {
                do {
                    for line in try self.splitter.feed(data) { self.handle(line) }
                } catch {
                    self.fail("Snapserver sent an oversized message.")
                    return
                }
            }
            if let error { self.fail(RelayClient.describe(error, service: "Snapserver's control port")) }
            else if isComplete { self.fail("Snapserver closed the connection.") }
            else { self.receive(on: c) }
        }
    }

    // MARK: JSON-RPC

    private func call(_ method: String, _ params: [String: Any]? = nil,
                      completion: @escaping (Result<Any, Error>) -> Void = { _ in }) {
        guard let connection else {
            struct NotConnected: LocalizedError { var errorDescription: String? { "Not connected." } }
            completion(.failure(NotConnected()))
            return
        }
        let id = nextID
        nextID += 1
        var request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { request["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return }
        data.append(0x0A)
        pending[id] = completion
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(RelayClient.describe(error, service: "Snapserver's control port")) }
        })
    }

    private func handle(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                struct RPCError: LocalizedError { let errorDescription: String? }
                completion(.failure(RPCError(errorDescription: error["message"] as? String ?? "Request failed.")))
            } else {
                completion(.success(message["result"] as Any))
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "Client.OnVolumeChanged", let id = params["id"] as? String,
           let volume = params["volume"] as? [String: Any],
           let i = snapshot.speakers.firstIndex(where: { $0.id == id }), wantedVolume[id] == nil {
            // Applied directly (no refetch): this is the common case while someone drags
            // a slider in Snapweb. Ignored while our own change is pending, to avoid
            // the slider jumping back to a stale echo.
            snapshot.speakers[i].percent = volume["percent"] as? Int ?? snapshot.speakers[i].percent
            snapshot.speakers[i].muted = volume["muted"] as? Bool ?? snapshot.speakers[i].muted
            publish(snapshot)
        } else {
            refresh()  // anything structural: connects, group and stream changes
        }
    }

    private func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Batches the burst of notifications a single change can cause.
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.call("Server.GetStatus") { result in
                guard case .success(let value) = result, let status = value as? [String: Any] else { return }
                var fresh = Self.parse(status: status)
                // Keep showing values we are still sending, rather than the server's older ones.
                for (id, v) in self.wantedVolume {
                    if let i = fresh.speakers.firstIndex(where: { $0.id == id }) {
                        fresh.speakers[i].percent = v.0
                        fresh.speakers[i].muted = v.1
                    }
                }
                self.snapshot = fresh
                self.publish(fresh)
            }
        }
    }

    private func change(_ id: String, _ mutate: (inout Speaker) -> Void) {
        guard let i = snapshot.speakers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&snapshot.speakers[i])
        wantedVolume[id] = (snapshot.speakers[i].percent, snapshot.speakers[i].muted)
        publish(snapshot)  // optimistic: the UI follows the slider, not the round trip
        sendVolume(id)
    }

    private func sendVolume(_ id: String) {
        guard !volumeInFlight.contains(id), let (percent, muted) = wantedVolume[id] else { return }
        volumeInFlight.insert(id)
        call("Client.SetVolume", ["id": id, "volume": ["percent": percent, "muted": muted]]) { [weak self] _ in
            guard let self else { return }
            self.volumeInFlight.remove(id)
            if let latest = self.wantedVolume[id], latest != (percent, muted) {
                self.sendVolume(id)  // the slider moved on while this was in flight
            } else {
                self.wantedVolume[id] = nil
            }
        }
    }

    private func publish(_ snapshot: Snapshot) {
        let cb = onSnapshot
        callbackQueue.async { cb(snapshot) }
    }

    private func publish(state: ConnectionState) {
        let cb = onState
        callbackQueue.async { cb(state) }
    }

    // MARK: Parsing

    /// Parses a Server.GetStatus result. Tolerant: unknown or missing fields are skipped.
    public static func parse(status: [String: Any]) -> Snapshot {
        var out = Snapshot()
        let server = status["server"] as? [String: Any] ?? [:]
        for stream in server["streams"] as? [[String: Any]] ?? [] {
            if let id = stream["id"] as? String { out.streams[id] = stream["status"] as? String ?? "" }
        }
        for group in server["groups"] as? [[String: Any]] ?? [] {
            let groupID = group["id"] as? String ?? ""
            let streamID = group["stream_id"] as? String ?? ""
            for client in group["clients"] as? [[String: Any]] ?? [] {
                guard let id = client["id"] as? String else { continue }
                let config = client["config"] as? [String: Any] ?? [:]
                let volume = config["volume"] as? [String: Any] ?? [:]
                let host = client["host"] as? [String: Any] ?? [:]
                let configured = config["name"] as? String ?? ""
                out.speakers.append(Speaker(
                    id: id,
                    name: configured.isEmpty ? (host["name"] as? String ?? id) : configured,
                    connected: client["connected"] as? Bool ?? false,
                    percent: volume["percent"] as? Int ?? 100,
                    muted: volume["muted"] as? Bool ?? false,
                    groupID: groupID,
                    streamID: streamID))
            }
        }
        out.speakers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return out
    }
}

/// Splits a byte stream into newline-terminated lines.
public struct LineSplitter {
    private var pending = Data()
    private let limit: Int
    public init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }

    public struct TooLong: Error {}

    public mutating func feed(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...nl)
        }
        if pending.count > limit { throw TooLong() }
        return lines
    }
}
