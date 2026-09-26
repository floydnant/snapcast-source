import AVFoundation
import XCTest
@testable import StreamCore

final class ByteRingTests: XCTestCase {
    func write(_ ring: ByteRing, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { ring.write($0.baseAddress!, bytes.count) }
    }

    func testReadsBackInOrderAcrossWraparound() {
        let ring = ByteRing(capacity: 16)
        write(ring, Array(0..<12))
        XCTAssertEqual(ring.read(maxLength: 8), Data(0..<8))
        write(ring, Array(12..<24))  // wraps
        XCTAssertEqual(ring.read(maxLength: 100), Data(8..<24))
        XCTAssertNil(ring.read(maxLength: 100))
    }

    func testOverflowDropsOldestWholeFrames() {
        let ring = ByteRing(capacity: 16)
        write(ring, Array(0..<16))
        write(ring, Array(16..<24))
        XCTAssertEqual(ring.droppedBytes, 8)
        XCTAssertEqual(ring.read(maxLength: 100), Data(8..<24), "oldest audio should be the part dropped")
    }

    func testOversizedWriteKeepsNewest() {
        let ring = ByteRing(capacity: 8)
        write(ring, Array(0..<20))
        XCTAssertEqual(ring.read(maxLength: 100), Data(12..<20))
    }

    func testReadsAreWholeFrames() {
        let ring = ByteRing(capacity: 16)
        write(ring, Array(0..<12))
        XCTAssertEqual(ring.read(maxLength: 7)?.count, 4)
    }
}

final class ProtocolTests: XCTestCase {
    func testHelloWireFormatMatchesRelay() throws {
        let data = try RelayProtocol.Hello(name: "Mac A").encoded()
        XCTAssertEqual(data.prefix(8), Data("SNAPSRC1".utf8))
        XCTAssertEqual(data.last, 0x0A)
        let json = try JSONSerialization.jsonObject(with: data.dropFirst(8).dropLast()) as! [String: String]
        // Field names are the relay's json tags; nil optionals must be omitted, not null.
        XCTAssertEqual(json, ["name": "Mac A", "format": "48000:16:2"])
    }

    func testParserHandlesSplitAndBatchedLines() throws {
        var parser = ControlLineParser()
        XCTAssertEqual(try parser.feed(Data(#"{"type":"wel"#.utf8)), [])
        let messages = try parser.feed(Data("come\"}\n{\"type\":\"ping\"}\n{\"type\":\"replaced\",\"by\":\"Mac B\"}\n".utf8))
        XCTAssertEqual(messages.map(\.type), ["welcome", "ping", "replaced"])
        XCTAssertEqual(messages.last?.by, "Mac B")
    }

    func testParserRejectsRunawayLine() {
        var parser = ControlLineParser(limit: 16)
        XCTAssertThrowsError(try parser.feed(Data(repeating: 0x41, count: 64)))
    }
}

final class RelayTargetTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(StreamEngine.RelayTarget(""), .automatic)
        XCTAssertEqual(StreamEngine.RelayTarget("  "), .automatic)
        XCTAssertEqual(StreamEngine.RelayTarget("server.local"), .manual(host: "server.local", port: 4953))
        XCTAssertEqual(StreamEngine.RelayTarget("192.0.2.10:5000"), .manual(host: "192.0.2.10", port: 5000))
        XCTAssertEqual(StreamEngine.RelayTarget("fe80::1"), .manual(host: "fe80::1", port: 4953))
        XCTAssertEqual(StreamEngine.RelayTarget("[fe80::1]:5000"), .manual(host: "fe80::1", port: 5000))
        XCTAssertNil(StreamEngine.RelayTarget("host:notaport"))
        XCTAssertNil(StreamEngine.RelayTarget(":4953"))
    }
}

final class PCMConverterTests: XCTestCase {
    /// Feeds one second of 44.1 kHz float stereo in tap-sized chunks and checks that
    /// what comes out is one second at 48 kHz — the whole point of converting.
    func testResamplesToExactly48kHz() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
        for format in [input, interleaved] {
            let converter = try PCMConverter(input: format)
            var outFrames = 0
            var peakOut: Int16 = 0
            let chunk: AVAudioFrameCount = 512
            var phase = 0.0
            for _ in 0..<(44_100 / Int(chunk)) {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
                buffer.frameLength = chunk
                let data = buffer.floatChannelData!
                for i in 0..<Int(chunk) {
                    let v = Float(sin(phase) * 0.5)
                    phase += 2 * .pi * 1000 / 44_100
                    if format.isInterleaved {
                        data[0][i * 2] = v; data[0][i * 2 + 1] = v
                    } else {
                        data[0][i] = v; data[1][i] = v
                    }
                }
                converter.convert(buffer.audioBufferList) { p, n in
                    outFrames += n / 4
                    let s = p.assumingMemoryBound(to: Int16.self)
                    for j in 0..<(n / 2) { peakOut = max(peakOut, abs(s[j])) }
                }
                XCTAssertEqual(converter.peak, 0.5, accuracy: 0.01)
            }
            let inFrames = Double(44_100 / Int(chunk) * Int(chunk))
            let expected = inFrames * 48_000 / 44_100
            // The resampler holds back a few frames of filter delay; nothing more.
            XCTAssertEqual(Double(outFrames), expected, accuracy: 64, "\(format)")
            XCTAssertEqual(Double(peakOut) / 32767, 0.5, accuracy: 0.02, "amplitude must survive conversion")
        }
    }
}
