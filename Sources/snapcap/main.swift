// snapcap — capture a macOS audio device and write raw s16le stereo PCM to stdout.
//
// Intended to be piped straight into a Snapcast `tcp://` stream source:
//
//     snapcap "BlackHole 16ch" | nc your-snapserver 4953
//
// WHY NOT JUST USE FFMPEG:
//
// ffmpeg's avfoundation input cannot sustain a normal audio sample rate. It delivers
// 512-frame buffers at a fixed ~80 per second, which caps it at 40,960 frames/s no
// matter what `-ar` you pass. 48 kHz needs 93.75 buffers/s and 44.1 kHz needs 86.1, so
// both starve and drop ~15% of samples — which sounds like constant breakup, and which
// no choice of sample rate can fix. Measured on this machine: BlackHole 16ch lost 15.4%,
// and the built-in microphone (unrelated device, 2 channels, real hardware) lost 17.1%,
// both showing the same 512-frames-at-80-Hz signature.
//
// Talking to the CoreAudio HAL directly avoids that path entirely. Measured over 40s,
// this delivers 48 kHz with no ongoing drift — the only shortfall is a fixed ~0.2-0.5s
// of device-open cost at startup, which does not accumulate.

import AudioToolbox
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("snapcap: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(("snapcap: " + message + "\n").data(using: .utf8)!)
}

/// Resolve a device by its exact name as shown in Audio MIDI Setup.
///
/// Binding by name (rather than driving the *default input*) is deliberate: it lets the
/// capture run without touching the user's system input selection.
func findDevice(named target: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }

    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
              let resolved = name?.takeRetainedValue() else { continue }
        if (resolved as String) == target { return id }
    }
    return nil
}

/// Byte ring drained by the main thread so the render callback never blocks on stdout.
///
/// The render callback runs on a realtime audio thread. A blocking `write()` there would
/// stall the whole device and cause exactly the dropouts this program exists to avoid, so
/// the callback only ever copies into this buffer and returns.
final class Ring {
    private let buf: UnsafeMutablePointer<UInt8>
    private let cap: Int
    private var head = 0, tail = 0, count = 0
    private let lock = NSCondition()
    private(set) var droppedBytes = 0

    init(capacity: Int) {
        cap = capacity
        buf = .allocate(capacity: capacity)
    }

    /// Called from the realtime thread. Drops rather than blocks when the reader falls
    /// behind — losing a slice is recoverable, wedging the audio device is not.
    func write(_ src: UnsafePointer<UInt8>, _ n: Int) {
        lock.lock()
        if cap - count < n {
            droppedBytes += n
            lock.unlock()
            return
        }
        for i in 0..<n { buf[(head + i) % cap] = src[i] }
        head = (head + n) % cap
        count += n
        lock.signal()
        lock.unlock()
    }

    /// Hands the consumer one contiguous span, so it never has to deal with wraparound.
    func drain(_ sink: (UnsafePointer<UInt8>, Int) -> Void) {
        lock.lock()
        while count == 0 { lock.wait() }
        let n = min(count, cap - tail)
        let start = tail
        tail = (tail + n) % cap
        count -= n
        lock.unlock()
        sink(buf + start, n)
    }
}

/// Everything the realtime callback needs, reachable through one opaque pointer.
final class Capture {
    let ring: Ring
    let channels: UInt32
    var unit: AudioUnit?
    let scratch: UnsafeMutableRawPointer
    let pcm: UnsafeMutablePointer<Int16>
    var bufferList: UnsafeMutableAudioBufferListPointer

    static let maxFrames = 8192

    init(ring: Ring, channels: UInt32) {
        self.ring = ring
        self.channels = channels
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        scratch = .allocate(byteCount: 4 * Int(channels) * Capture.maxFrames, alignment: 16)
        pcm = .allocate(capacity: 2 * Capture.maxFrames)
    }
}

let deviceName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BlackHole 16ch"
guard let device = findDevice(named: deviceName) else {
    fail("audio device not found: \(deviceName)")
}

var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &desc) else { fail("no HAL output component") }

var unitOpt: AudioUnit?
guard AudioComponentInstanceNew(component, &unitOpt) == noErr, let unit = unitOpt else {
    fail("could not instantiate HAL output unit")
}

// Bus 1 is the hardware input side, bus 0 the output side. We want input only.
var enable: UInt32 = 1
var disable: UInt32 = 0
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4)
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4)

var boundDevice = device
guard AudioUnitSetProperty(
    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
    &boundDevice, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
    fail("could not bind to device: \(deviceName)")
}

var hardware = AudioStreamBasicDescription()
var hardwareSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(
    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &hardwareSize)
let sampleRate = hardware.mSampleRate
let channels = hardware.mChannelsPerFrame
guard sampleRate > 0, channels >= 2 else {
    fail("device reports an unusable format (\(sampleRate) Hz, \(channels) ch)")
}

// Ask for float32 at the device's own rate and channel count. Requesting a different rate
// here would insert a converter and reintroduce drift; Snapcast is told the real rate
// instead, via `sampleformat` on the stream source.
var client = AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4 * channels,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4 * channels,
    mChannelsPerFrame: channels,
    mBitsPerChannel: 32,
    mReserved: 0)
guard AudioUnitSetProperty(
    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
    &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
    fail("device rejected float32 client format")
}

let capture = Capture(ring: Ring(capacity: 1 << 20), channels: channels)
capture.unit = unit

let renderCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let ctx = Unmanaged<Capture>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = ctx.unit, Int(frames) <= Capture.maxFrames else { return noErr }

    ctx.bufferList[0] = AudioBuffer(
        mNumberChannels: ctx.channels,
        mDataByteSize: 4 * ctx.channels * frames,
        mData: ctx.scratch)

    let status = AudioUnitRender(unit, flags, timestamp, bus, frames, ctx.bufferList.unsafeMutablePointer)
    if status != noErr { return status }

    // Take channels 1-2 verbatim rather than downmixing. On a 16-channel device a real
    // downmix would fold 14 silent channels into the pair and shift the levels.
    let samples = ctx.scratch.assumingMemoryBound(to: Float.self)
    let stride = Int(ctx.channels)
    for frame in 0..<Int(frames) {
        for channel in 0..<2 {
            let clamped = max(-1.0, min(1.0, samples[frame * stride + channel]))
            ctx.pcm[frame * 2 + channel] = Int16(clamped * 32767.0)
        }
    }

    let byteCount = 4 * Int(frames)  // 2 channels x 2 bytes
    ctx.pcm.withMemoryRebound(to: UInt8.self, capacity: byteCount) {
        ctx.ring.write($0, byteCount)
    }
    return noErr
}

var callbackStruct = AURenderCallbackStruct(
    inputProc: renderCallback,
    inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
AudioUnitSetProperty(
    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
    &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

var maxFrames = UInt32(Capture.maxFrames)
AudioUnitSetProperty(
    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)

guard AudioUnitInitialize(unit) == noErr else { fail("AudioUnitInitialize failed") }
guard AudioOutputUnitStart(unit) == noErr else { fail("AudioOutputUnitStart failed") }

note("\(deviceName) @ \(Int(sampleRate)) Hz, \(channels) ch -> stdout s16le 2ch")
note("snapserver stream source should declare sampleformat=\(Int(sampleRate)):16:2")

// SIGPIPE would kill us silently when the downstream `nc` goes away; ignoring it turns
// that into a normal short write we can exit on cleanly.
signal(SIGPIPE, SIG_IGN)

let stdoutFD = FileHandle.standardOutput.fileDescriptor
while true {
    capture.ring.drain { ptr, count in
        var offset = 0
        while offset < count {
            let written = write(stdoutFD, ptr + offset, count - offset)
            if written <= 0 {
                AudioOutputUnitStop(unit)
                exit(0)
            }
            offset += written
        }
    }
}
