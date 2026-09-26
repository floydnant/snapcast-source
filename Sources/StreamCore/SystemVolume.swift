import AudioToolbox
import CoreAudio
import Foundation

/// Follows the Mac's output volume and mute, so the volume keys keep working while
/// streaming.
///
/// This is needed because the tap captures what apps play BEFORE the output device's
/// volume is applied. With local output muted, the volume keys would otherwise change
/// nothing anyone can hear.
///
/// Devices without a software volume (audio interfaces with a hardware knob, typically)
/// report `supported == false`; `factor` is then 1 and only the app's slider applies.
public final class SystemVolumeWatcher {
    public struct Info: Equatable {
        public var deviceName: String
        public var supported: Bool
        public var scalar: Float
        public var muted: Bool
        /// Multiplier for the stream: 0 when muted, the volume position otherwise.
        public var factor: Float { supported ? (muted ? 0 : scalar) : 1 }

        public init(deviceName: String, supported: Bool, scalar: Float, muted: Bool) {
            self.deviceName = deviceName
            self.supported = supported
            self.scalar = scalar
            self.muted = muted
        }
    }

    public private(set) var info = Info(deviceName: "", supported: false, scalar: 1, muted: false)

    private let queue: DispatchQueue
    private let onChange: (Info) -> Void
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var propertyListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// Must be created on `queue`; `onChange` is called there.
    public init(queue: DispatchQueue, onChange: @escaping (Info) -> Void) {
        self.queue = queue
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, queue, listener)
        rebind()
    }

    deinit {
        unbind()
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, queue, deviceListener)
        }
    }

    private func rebind() {
        unbind()
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        device = id
        if id != kAudioObjectUnknown {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read() }
            propertyListener = listener
            if AudioObjectHasProperty(id, &Self.volume) {
                AudioObjectAddPropertyListenerBlock(id, &Self.volume, queue, listener)
            }
            if AudioObjectHasProperty(id, &Self.mute) {
                AudioObjectAddPropertyListenerBlock(id, &Self.mute, queue, listener)
            }
        }
        read()
    }

    private func unbind() {
        guard device != kAudioObjectUnknown, let propertyListener else { return }
        AudioObjectRemovePropertyListenerBlock(device, &Self.volume, queue, propertyListener)
        AudioObjectRemovePropertyListenerBlock(device, &Self.mute, queue, propertyListener)
        self.propertyListener = nil
    }

    private func read() {
        var new = Info(deviceName: Self.name(of: device), supported: false, scalar: 1, muted: false)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &Self.volume),
           AudioObjectIsPropertySettable(device, &Self.volume, &settable) == noErr, settable.boolValue {
            var value: Float32 = 1
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &value) == noErr {
                new.supported = true
                new.scalar = max(0, min(1, value))
            }
        }
        if AudioObjectHasProperty(device, &Self.mute) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &value) == noErr {
                new.muted = value != 0
            }
        }
        guard new != info else { return }
        info = new
        onChange(new)
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let resolved = name?.takeRetainedValue() else { return "" }
        return resolved as String
    }
}

/// Maps a volume *position* (slider, or the system's scalar) to linear gain. Cubic,
/// because loudness is perceived roughly logarithmically: a linear map puts nearly all
/// of the audible range in the bottom fifth of the slider.
public enum VolumeCurve {
    public static func gain(forPosition position: Float) -> Float {
        let p = max(0, min(1, position))
        return p * p * p
    }
}

/// Gain shared between the engine (writer) and the audio thread (reader).
public final class GainControl {
    private var lock = os_unfair_lock()
    private var _value: Float
    public init(_ value: Float = 1) { _value = value }
    public var value: Float {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _value }
        set { os_unfair_lock_lock(&lock); _value = newValue; os_unfair_lock_unlock(&lock) }
    }
}
