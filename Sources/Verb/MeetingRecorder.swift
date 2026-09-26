import AVFoundation
import AudioToolbox
import CoreAudio
import VerbCore

/// Records a meeting on this Mac: your microphone, and what the Mac plays (the others in a
/// call), each in its own 16 kHz file. No bot joins the call, and the recordings stay on the Mac.
@MainActor final class MeetingRecorder {
    private(set) var started: Date?
    private(set) var folder: URL?
    private var engine: AVAudioEngine?
    private var microphone: TrackWriter?
    private var system: AnyObject?
    private var configurationObserver: NSObjectProtocol?
    /// Why the Mac's sound can't be recorded, when it can't; the meeting goes on with the microphone.
    private(set) var systemProblem: String?
    var isRecording: Bool { started != nil }

    func start(in folder: URL, microphone device: AudioDeviceID?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let writer = try TrackWriter(url: folder.appendingPathComponent("you.wav"))
        let engine = AVAudioEngine(), input = engine.inputNode
        if var device, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VerbError("No microphone is available.") }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in writer.write(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine; microphone = writer
        // A headset plugged in or taken out stops the engine: it starts again on the new input, into the same file.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartMicrophone() }
        }
        systemProblem = nil
        if #available(macOS 14.2, *) {
            let tap = SystemAudioTap()
            do { try tap.start(writingTo: folder.appendingPathComponent("others.wav")); system = tap }
            catch { systemProblem = error.localizedDescription }
        } else { systemProblem = "Recording the Mac's sound needs macOS 14.2 or later." }
        started = Date(); self.folder = folder
    }

    /// Stops both tracks. `othersPeak` is how loud the Mac's sound got: near zero, nothing came through.
    private func restartMicrophone() {
        guard let engine, let writer = microphone else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in writer.write(buffer) }
        engine.prepare(); try? engine.start()
    }

    func stop() -> (folder: URL, started: Date, duration: Double, othersPeak: Float?)? {
        guard let started, let folder else { return nil }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        microphone?.close(); microphone = nil
        var peak: Float?
        if #available(macOS 14.2, *), let tap = system as? SystemAudioTap { tap.stop(); peak = tap.peak }
        system = nil
        self.started = nil; self.folder = nil
        return (folder, started, Date().timeIntervalSince(started), peak)
    }
}

/// Turns any audio into 16 kHz mono and writes it, on its own queue, so the audio thread
/// never waits for the disk.
final class TrackWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.verb.meeting-track", qos: .userInitiated)
    private var file: AVAudioFile?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var loudest: Float = 0
    var peak: Float { queue.sync { loudest } }

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        // Other people's voices: readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Takes a buffer the audio system will reuse: it is copied before it leaves.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, destination.count) {
            if let from = source[i].mData, let to = destination[i].mData { memcpy(to, from, Int(min(source[i].mDataByteSize, destination[i].mDataByteSize))) }
        }
        queue.async { [self] in
            guard let file else { return }
            if converter == nil || converter?.inputFormat != copy.format {
                converter = AVAudioConverter(from: copy.format, to: target); converter?.downmix = true
            }
            guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / copy.format.sampleRate)) + 64) else { return }
            var supplied = false, error: NSError?
            converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return copy
            }
            guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            for i in 0..<Int(output.frameLength) { loudest = max(loudest, abs(channel[i])) }
            try? file.write(from: output)
        }
    }

    /// Writes what is left and closes the file.
    func close() { queue.sync { file = nil } }
}

/// What the Mac plays, through a Core Audio process tap: the voices of a call, a video, any
/// app, Verb's own sounds aside. The first time, macOS asks whether Verb may record it.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let queue = DispatchQueue(label: "app.verb.system-audio", qos: .userInitiated)
    var peak: Float { writer?.peak ?? 0 }

    func start(writingTo url: URL) throws {
        let own = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true
        description.name = "Verb meeting"
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw VerbError("Verb couldn't record the Mac's sound (Core Audio error \(status)).") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &stream) else { stop(); throw VerbError("Verb couldn't read the format of the Mac's sound.") }
        guard let output = Self.defaultOutputUID() else { stop(); throw VerbError("The Mac has no sound output to record.") }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verb meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw VerbError("Verb couldn't open the Mac's sound (Core Audio error \(status)).") }
        let writer = try TrackWriter(url: url)
        self.writer = writer
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.write(buffer)
        }
        guard status == noErr, let proc else { stop(); throw VerbError("Verb couldn't listen to the Mac's sound (Core Audio error \(status)).") }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { stop(); throw VerbError("Verb couldn't start recording the Mac's sound (Core Audio error \(status)).") }
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil; aggregate = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
        writer?.close()
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid, object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?, uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
