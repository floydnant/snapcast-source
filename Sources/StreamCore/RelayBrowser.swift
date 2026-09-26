import Foundation
import Network

/// Finds relays on the local network via Bonjour, so no host or IP is configured.
public final class RelayBrowser {
    public struct Relay: Hashable, Identifiable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }

    private let browser: NWBrowser
    private let queue: DispatchQueue
    private let onChange: ([Relay]) -> Void

    public init(queue: DispatchQueue, onChange: @escaping ([Relay]) -> Void) {
        self.queue = queue
        self.onChange = onChange
        browser = NWBrowser(for: .bonjour(type: RelayProtocol.serviceType, domain: "local."), using: NWParameters())
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let relays = results.compactMap { result -> Relay? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Relay(name: name, endpoint: result.endpoint)
            }
            // A multihomed host shows up once per interface; one entry per name is enough.
            var seen = Set<String>()
            let unique = relays.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
            self?.onChange(unique)
        }
        browser.start(queue: queue)
    }

    public func cancel() { browser.cancel() }
}
