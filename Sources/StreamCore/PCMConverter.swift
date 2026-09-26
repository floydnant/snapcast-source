import AVFoundation
import Accelerate

/// Converts whatever the tap produces into the relay's one fixed format.
public final class PCMConverter {
    public enum ConvertError: LocalizedError {
        case unsupported(AVAudioFormat)
        public var errorDescription: String? {
            if case .unsupported(let f) = self { return "Cannot convert from \(f)." }
            return nil
        }
    }

    public let input: AVAudioFormat
    public let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let outBuffer: AVAudioPCMBuffer
    private let maxInputFrames: AVAudioFrameCount

    /// Peak magnitude of the most recent input buffer, 0...1.
    public private(set) var peak: Float = 0

    public init(input: AVAudioFormat, maxInputFrames: AVAudioFrameCount = 16_384) throws {
        self.input = input
        self.maxInputFrames = maxInputFrames
        output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: RelayProtocol.sampleRate,
            channels: AVAudioChannelCount(RelayProtocol.channels),
            interleaved: true)!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw ConvertError.unsupported(input)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter

        let capacity = AVAudioFrameCount((Double(maxInputFrames) * output.sampleRate / input.sampleRate).rounded(.up)) + 256
        outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
    }

    /// Converts one tap buffer and hands the interleaved s16le bytes to `sink`. The
    /// resampler keeps its state between calls, so successive buffers form one
    /// continuous stream rather than independently-resampled blocks.
    public func convert(_ list: UnsafePointer<AudioBufferList>, sink: (UnsafeRawPointer, Int) -> Void) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }
        let bytesPerFrame = input.streamDescription.pointee.mBytesPerFrame
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0, frames <= maxInputFrames,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: list, deallocator: nil)
        else { return }
        inBuffer.frameLength = frames
        peak = Self.peak(of: buffers, isFloat: input.commonFormat == .pcmFormatFloat32)

        var fed = false
        outBuffer.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, outBuffer.frameLength > 0, let data = outBuffer.int16ChannelData else { return }
        sink(data[0], Int(outBuffer.frameLength) * RelayProtocol.bytesPerFrame)
    }

    private static func peak(of buffers: UnsafeMutableAudioBufferListPointer, isFloat: Bool) -> Float {
        guard isFloat else { return 0 }
        var result: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            var m: Float = 0
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(buffer.mDataByteSize / 4))
            result = max(result, m)
        }
        return min(result, 1)
    }
}
