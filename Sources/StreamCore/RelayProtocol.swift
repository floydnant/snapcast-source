import Foundation

/// Wire protocol v1, shared with `relay/relay.go`. See the comment at the top of that
/// file for the full description; the two must change together.
public enum RelayProtocol {
    public static let magic = Data("SNAPSRC1".utf8)
    public static let serviceType = "_snapcast-src._tcp"
    public static let defaultPort: UInt16 = 4953

    /// The one format every source sends, whatever the Mac's hardware is doing. Fixed
    /// because a Snapcast stream's `sampleformat` is fixed at config time: resampling
    /// here means plugging in a 44.1 kHz interface mid-session changes nothing
    /// downstream.
    public static let sampleRate: Double = 48_000
    public static let channels = 2
    public static let bytesPerFrame = 4
    public static let format = "48000:16:2"

    public struct Hello: Codable, Equatable {
        public var mode: String?
        public var name: String
        public var format: String?
        public var token: String?

        public init(mode: String? = nil, name: String, format: String? = RelayProtocol.format, token: String? = nil) {
            self.mode = mode
            self.name = name
            self.format = format
            self.token = token
        }

        /// Magic + one JSON line, ready to write.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var data = RelayProtocol.magic
            data.append(try encoder.encode(self))
            data.append(0x0A)
            return data
        }
    }

    public struct Control: Codable, Equatable {
        public var type: String
        public var by: String?
        public var reason: String?
        public var active: String?
        public var since: Int64?
        public var format: String?
    }
}

/// Splits a byte stream into newline-delimited control messages.
public struct ControlLineParser {
    private var pending = Data()
    private let limit: Int

    public init(limit: Int = 4096) { self.limit = limit }

    public enum ParseError: Error { case lineTooLong, badMessage(String) }

    public mutating func feed(_ data: Data) throws -> [RelayProtocol.Control] {
        pending.append(data)
        var out: [RelayProtocol.Control] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            guard !line.isEmpty else { continue }
            do {
                out.append(try JSONDecoder().decode(RelayProtocol.Control.self, from: Data(line)))
            } catch {
                throw ParseError.badMessage(String(decoding: line, as: UTF8.self))
            }
        }
        if pending.count > limit { throw ParseError.lineTooLong }
        return out
    }
}
