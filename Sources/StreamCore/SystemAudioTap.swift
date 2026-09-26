import AVFoundation
import AudioToolbox
import CoreAudio

/// Anything that can feed the engine audio. The system tap in production; a fake in tests.
public protocol AudioCapture: AnyObject {
    var format: AVAudioFormat { get }
    func start(_ handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws
    func stop()
}

/// Captures the mixdown of everything the Mac is playing, via a CoreAudio process tap
/// (macOS 14.2+). No virtual audio driver involved.
///
/// The tap is read through a private aggregate device that contains ONLY the tap. The
/// usual recipe also adds the current output device as the aggregate's main subdevice
/// for clocking, but an interface with inputs (a Scarlett 8i6, say) then contributes
/// its own input channels to the same buffer list — measured here as `10ch + 2ch` —
/// and the tap is no longer the only thing in it. The tap-only aggregate clocks
/// correctly on its own.
///
/// Both the tap and the aggregate are private, so they are invisible to other apps and
/// die with this process: a crash cannot leave the Mac muted.
public final class SystemAudioTap: AudioCapture {
    public enum TapError: LocalizedError {
        case createTap(OSStatus)
        case readFormat(OSStatus)
        case unsupportedFormat
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .createTap(let s): return "Could not create the system audio tap (\(s))."
            case .readFormat(let s): return "Could not read the tap's audio format (\(s))."
            case .unsupportedFormat: return "The tap reported an audio format that cannot be converted."
            case .createAggregate(let s): return "Could not create the capture device (\(s))."
            case .createIOProc(let s): return "Could not attach to the capture device (\(s))."
            case .start(let s): return "Could not start capturing (\(s))."
            }
        }
    }

    public let format: AVAudioFormat
    public let muteLocal: Bool

    private let tapUUID = UUID()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue: DispatchQueue
    private var stopped = false

    private static var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// - Parameters:
    ///   - muteLocal: silence the Mac's own output while capturing, so audio plays in the
    ///     house instead of on this Mac. Local playback returns the moment capture stops.
    ///   - onFormatChange: the tap's format follows the output device, so it can change
    ///     under a running capture (switching to a 44.1 kHz interface, for instance).
    ///     Called on `queue`; the owner should rebuild.
    public init(muteLocal: Bool, queue: DispatchQueue, onFormatChange: @escaping () -> Void) throws {
        self.muteLocal = muteLocal
        self.listenerQueue = queue

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = tapUUID
        description.name = "Snapcast Source"
        description.isPrivate = true
        description.muteBehavior = muteLocal ? .mutedWhenTapped : .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &Self.formatAddress, 0, nil, &size, &asbd)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.readFormat(status)
        }
        guard asbd.mSampleRate > 0, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.unsupportedFormat
        }
        format = fmt

        let listener: AudioObjectPropertyListenerBlock = { _, _ in onFormatChange() }
        formatListener = listener
        AudioObjectAddPropertyListenerBlock(tapID, &Self.formatAddress, queue, listener)
    }

    /// Starts delivering buffers to `handler` on the HAL's realtime IO thread. The
    /// handler must not block.
    public func start(_ handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Snapcast Source Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.createAggregate(status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            handler(input)
        }
        guard status == noErr else { throw TapError.createIOProc(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.start(status) }
    }

    /// Idempotent. Local playback unmutes as soon as this returns.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if let formatListener {
            AudioObjectRemovePropertyListenerBlock(tapID, &Self.formatAddress, listenerQueue, formatListener)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    deinit { stop() }
}
