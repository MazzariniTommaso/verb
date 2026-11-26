import AudioToolbox
import AVFoundation
import CoreAudio
import IOKit
import os
import VerbCore

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let deviceID: AudioDeviceID
    public var transport: UInt32 = 0
    /// What it is, or nil for a device nobody speaks into. See `MicrophoneChoice.Kind`.
    public var kind: MicrophoneChoice.Kind?
    public init(id: String, name: String, deviceID: AudioDeviceID, transport: UInt32 = 0, kind: MicrophoneChoice.Kind? = nil) {
        self.id = id; self.name = name; self.deviceID = deviceID; self.transport = transport
        self.kind = kind ?? MicrophoneChoice.kind(transport: transport, external: false)
    }
    public var isBuiltIn: Bool { kind == .builtIn }
    public var isBluetooth: Bool { kind == .headset }
    var choice: MicrophoneChoice.Device { MicrophoneChoice.Device(id: id, kind: kind) }
}

public enum Microphones {
    /// The input macOS uses when none is chosen.
    public static func systemDefault() -> MicrophoneDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return list().first { $0.deviceID == device }
    }
    /// The microphone a dictation or a meeting uses now, and whether it stands in for a chosen
    /// one that is missing. See `MicrophoneChoice`; `preferBuiltIn` puts the Mac's own before
    /// Bluetooth headphones.
    public static func pick(_ chosen: String, preferBuiltIn: Bool) -> (device: MicrophoneDevice, standIn: Bool)? {
        let devices = list()
        guard let pick = MicrophoneChoice.pick(chosen: chosen, devices: devices.map(\.choice), systemDefault: systemDefault()?.id, headsetFirst: !preferBuiltIn, lidClosed: lidClosed),
              let device = devices.first(where: { $0.id == pick.id }) else { return nil }
        return (device, pick.standIn)
    }
    /// Whether the laptop's lid is closed, as with an external display.
    public static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }
    public static func list() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        return devices.compactMap { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport = UInt32(0), transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport)
            // A headset in the jack: the Mac's own input set to its external source, or a device of its own.
            var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var source = UInt32(0), sourceSize = UInt32(MemoryLayout<UInt32>.size)
            let external = (AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &sourceSize, &source) == noErr && source == 0x656D_6963) || uid.contains("Headphone")
            return MicrophoneDevice(id: uid, name: string(device, kAudioObjectPropertyName) ?? "", deviceID: device, transport: transport,
                                    kind: MicrophoneChoice.kind(transport: transport, external: external))
        }
    }
}

/// One microphone, read straight from its own Core Audio input unit. AVAudioEngine is not used
/// for this: its input first opens the system's default input together with the default output,
/// which puts Bluetooth headphones into call quality even when another microphone is wanted, and
/// once moved to another device it goes on reporting the first device's format.
public final class MicrophoneInput: @unchecked Sendable {
    public enum Change: Sendable { case lost, format }
    public let device: MicrophoneDevice
    /// What `deliver` receives: 32-bit float, one buffer per channel, at the device's own rate.
    public let format: AVAudioFormat
    /// The device went away or changed its rate, and the input has stopped. Called once, on the main queue.
    public var onChange: (@Sendable (Change) -> Void)?
    /// Gets about 20 ms at a time on the audio thread, in a buffer that is used again: copy it.
    private let deliver: @Sendable (AVAudioPCMBuffer) -> Void
    private let unit: AudioUnit
    private let rendered: AVAudioPCMBuffer
    private let staging: AVAudioPCMBuffer
    // Main queue only.
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var started = false, disposed = false, changed = false
    private static let log = Logger(subsystem: "app.verb.dictation", category: "audio")

    public init(_ device: MicrophoneDevice, deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description) else { throw VerbError("No microphone is available.") }
        try Self.check(AudioComponentInstanceNew(component, &made), "create the input unit", device)
        guard let unit = made else { throw VerbError("No microphone is available.") }
        do {
            var on: UInt32 = 1, off: UInt32 = 0, id = device.deviceID
            let flag = UInt32(MemoryLayout<UInt32>.size)
            // Input on and output off before the device is set: the unit then never opens an output.
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flag), "turn on input", device)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flag), "turn off output", device)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "select the device", device)
            var hardware = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the format", device)
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame, interleaved: false) else {
                throw VerbError("No microphone is available.")
            }
            var client = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set the format", device)
            var slice: UInt32 = 0, sliceSize = flag
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &sliceSize)
            guard let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(slice, 4096)),
                  let staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, (format.sampleRate / 50).rounded()))) else {
                throw VerbError("No microphone is available.")
            }
            self.device = device; self.format = format; self.deliver = deliver; self.unit = unit; self.rendered = rendered; self.staging = staging
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        var callback = AURenderCallbackStruct(inputProc: Self.render, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "listen to the device", device)
    }
    deinit { stop() }

    /// Starts the device. Call on the main queue.
    public func start() throws {
        guard !started, !disposed else { return }
        let begun = Date()
        try Self.check(AudioUnitInitialize(unit), "prepare the input", device)
        do { try Self.check(AudioOutputUnitStart(unit), "start the input", device) } catch { AudioUnitUninitialize(unit); throw error }
        started = true
        watch(kAudioDevicePropertyDeviceIsAlive) { [device] in
            var alive = UInt32(1)
            return Self.read(device.deviceID, kAudioDevicePropertyDeviceIsAlive, &alive) && alive == 0 ? .lost : nil
        }
        watch(kAudioDevicePropertyNominalSampleRate) { [device, format] in
            var rate = Float64(0)
            return Self.read(device.deviceID, kAudioDevicePropertyNominalSampleRate, &rate) && rate > 0 && rate != format.sampleRate ? .format : nil
        }
        let name = device.name, transport = device.transport, rate = Int(format.sampleRate), channels = format.channelCount, took = Int(Date().timeIntervalSince(begun) * 1000)
        Self.log.notice("Microphone started: \(name, privacy: .private), transport \(transport, privacy: .public), \(rate, privacy: .public) Hz, \(channels, privacy: .public) ch, in \(took, privacy: .public) ms")
    }
    /// Stops and lets the device go. Call on the main queue; nothing is delivered afterwards.
    public func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device.deviceID, &address, .main, block)
        }
        listeners = []
        guard !disposed else { return }
        disposed = true
        if started { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); Self.log.notice("Microphone stopped") }
        AudioComponentInstanceDispose(unit)
    }

    private func watch(_ selector: AudioObjectPropertySelector, _ change: @escaping @Sendable () -> Change?) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.changed, !self.disposed, let change = change() else { return }
            self.changed = true
            Self.log.notice("Microphone changed: \(change == .lost ? "gone" : "new format", privacy: .public)")
            self.stop()
            self.onChange?(change)
        }
        if AudioObjectAddPropertyListenerBlock(device.deviceID, &address, .main, block) == noErr { listeners.append((address, block)) }
    }
    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
    private static func check(_ status: OSStatus, _ step: String, _ device: MicrophoneDevice) throws {
        guard status != noErr else { return }
        log.error("Microphone couldn’t \(step, privacy: .public): OSStatus \(status, privacy: .public), transport \(device.transport, privacy: .public)")
        throw VerbError(step.hasPrefix("start") || step.hasPrefix("prepare") ? "The microphone couldn’t start. Choose another one in Settings." : "Could not select that microphone.")
    }

    /// The device has audio: render it into `rendered`, then pass it on in 20 ms pieces.
    private static let render: AURenderCallback = { refCon, flags, timeStamp, _, frames, _ in
        Unmanaged<MicrophoneInput>.fromOpaque(refCon).takeUnretainedValue().pull(flags, timeStamp, frames)
    }
    private func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard frames <= rendered.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        rendered.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, rendered.mutableAudioBufferList)
        guard status == noErr, let source = rendered.floatChannelData, let target = staging.floatChannelData else { return status }
        var done = 0
        while done < Int(frames) {
            let at = Int(staging.frameLength), count = min(Int(staging.frameCapacity) - at, Int(frames) - done)
            for channel in 0..<Int(format.channelCount) { (target[channel] + at).update(from: source[channel] + done, count: count) }
            staging.frameLength += AVAudioFrameCount(count); done += count
            if staging.frameLength == staging.frameCapacity { deliver(staging); staging.frameLength = 0 }
        }
        return noErr
    }
}
