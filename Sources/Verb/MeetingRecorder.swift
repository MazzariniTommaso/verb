import AVFoundation
import AudioToolbox
import CoreAudio
import VerbCore
import VerbEngine

/// Records a meeting on this Mac: your microphone, and what the Mac plays (the others in a
/// call), each in its own 16 kHz file. No bot joins the call, and the recordings stay on the Mac.
@MainActor final class MeetingRecorder {
    private(set) var started: Date?
    private(set) var folder: URL?
    private var input: MicrophoneInput?
    private var microphone: TrackWriter?
    private var system: AnyObject?
    /// The microphone as chosen in Settings, empty for the system's, to pick again after a change.
    private var choice = ""
    private var preferBuiltIn = true
    private var restarts = RestartBudget()
    /// Why the Mac's sound can't be recorded, when it can't; the meeting goes on with the microphone.
    private(set) var systemProblem: String?
    var isRecording: Bool { started != nil }
    /// Something went wrong while recording: a track stopped, or the disk did. Said once each.
    var onProblem: ((String) -> Void)?
    private var watchdog: Task<Void, Never>?
    private var said = Set<String>()

    func start(in folder: URL, microphone choice: String, preferBuiltIn: Bool) throws {
        guard let pick = Microphones.pick(choice, preferBuiltIn: preferBuiltIn) else { throw VerbError("No microphone is available.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let writer = try TrackWriter(url: folder.appendingPathComponent("you.wav"))
        self.choice = choice; self.preferBuiltIn = preferBuiltIn; restarts.reset()
        try openMicrophone(pick.device, into: writer)
        microphone = writer
        systemProblem = nil
        if #available(macOS 14.2, *) {
            let tap = SystemAudioTap()
            do { try tap.start(writingTo: folder.appendingPathComponent("others.wav")); system = tap }
            catch { systemProblem = error.localizedDescription }
        } else { systemProblem = "Recording the Mac's sound needs macOS 14.2 or later." }
        started = Date(); self.folder = folder
        said = []
        watch()
    }

    /// Both tracks keep growing while the meeting runs, silence included: one that stops, or a
    /// disk that refuses them, is said at once rather than found in the notes.
    private func watch() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.started != nil else { return }
                var tracks: [(TrackWriter, String)] = []
                if let microphone = self.microphone { tracks.append((microphone, "Your microphone stopped recording. The meeting keeps what it has; stop it and start again.")) }
                if #available(macOS 14.2, *), let tap = self.system as? SystemAudioTap, let writer = tap.track { tracks.append((writer, "The others’ sound stopped coming through. Your microphone is still recording.")) }
                for (writer, stalled) in tracks {
                    let health = writer.health
                    if let failure = health.failure { self.say("The disk couldn’t keep the meeting: \(failure)") }
                    else if Date().timeIntervalSince(health.last) > 8 { self.say(stalled) }
                }
            }
        }
    }
    private func say(_ problem: String) {
        guard !said.contains(problem) else { return }
        said.insert(problem); onProblem?(problem)
    }

    private func openMicrophone(_ device: MicrophoneDevice, into writer: TrackWriter) throws {
        let input = try MicrophoneInput(device) { buffer in writer.write(buffer) }
        input.onChange = { [weak self] change in MainActor.assumeIsolated { self?.microphoneChanged(change) } }
        try input.start()
        self.input = input
    }
    /// A headset plugged in or taken out: the meeting goes on in the same file, on the same
    /// microphone if it is still there or on the one Verb would pick now. A device that keeps
    /// changing is given up on, and said so.
    private func microphoneChanged(_ change: MicrophoneInput.Change) {
        let previous = input?.device
        input = nil
        guard started != nil, let writer = microphone else { return }
        let stopped = "Your microphone couldn’t start again after it changed. Stop the meeting to keep what was recorded."
        guard restarts.allow(at: Date().timeIntervalSinceReferenceDate) else { say(stopped); return }
        if change == .format, let previous, let same = Microphones.list().first(where: { $0.deviceID == previous.deviceID }),
           (try? openMicrophone(same, into: writer)) != nil { return }
        if let pick = Microphones.pick(choice, preferBuiltIn: preferBuiltIn), (try? openMicrophone(pick.device, into: writer)) != nil { return }
        say(stopped)
    }

    /// Stops both tracks. `othersPeak` is how loud the Mac's sound got: near zero, nothing came through.
    func stop() -> (folder: URL, started: Date, duration: Double, othersPeak: Float?)? {
        guard let started, let folder else { return nil }
        watchdog?.cancel(); watchdog = nil
        input?.stop(); input = nil
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
    private var failure: String?
    private var lastWrite = Date()
    var peak: Float { queue.sync { loudest } }
    /// The first error writing the file, and when audio last arrived.
    var health: (failure: String?, last: Date) { queue.sync { (failure, lastWrite) } }

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
            lastWrite = Date()
            guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            for i in 0..<Int(output.frameLength) { loudest = max(loudest, abs(channel[i])) }
            do { try file.write(from: output) } catch { if failure == nil { failure = error.localizedDescription } }
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
    /// Opening and closing the device happen apart from the audio's own queue, which stopping waits for.
    private let control = DispatchQueue(label: "app.verb.system-audio-control", qos: .userInitiated)
    private var format: AVAudioFormat?
    private var tapID = UUID()
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// The tap's own buffers, picked out of everything the device reads.
    private var view: UnsafeMutableAudioBufferListPointer?
    var peak: Float { writer?.peak ?? 0 }
    var track: TrackWriter? { writer }

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
        self.format = format; tapID = description.uuid
        view = AudioBufferList.allocate(maximumBuffers: format.isInterleaved ? 1 : Int(format.channelCount))
        do { writer = try TrackWriter(url: url); try open() } catch { stop(); throw error }
        // Another output, as headphones plugged in mid-call: the sound is followed there.
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reopen() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, control, listener) == noErr { outputListener = listener }
    }

    /// The device that reads the tap, clocked by the output in use. Its input holds the output's
    /// own inputs first, as a USB headset's microphone, then the tap: only the tap is written.
    private func open() throws {
        guard let format, let writer, let view else { return }
        guard let output = Self.defaultOutputUID() else { throw VerbError("The Mac has no sound output to record.") }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verb meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapID.uuidString]],
        ]
        var status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { aggregate = AudioObjectID(kAudioObjectUnknown); throw VerbError("Verb couldn't open the Mac's sound (Core Audio error \(status)).") }
        let skip = Self.inputBuffers(of: output), needed = view.count
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count >= needed else { return }
            let first = buffers.count >= skip + needed ? skip : buffers.count - needed
            for index in 0..<needed { view[index] = buffers[first + index] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: view.unsafePointer, deallocator: nil) else { return }
            writer.write(buffer)
        }
        guard status == noErr, let proc else { closeDevice(); throw VerbError("Verb couldn't listen to the Mac's sound (Core Audio error \(status)).") }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { closeDevice(); throw VerbError("Verb couldn't start recording the Mac's sound (Core Audio error \(status)).") }
    }
    /// Runs on the control queue when the output changes: the old device goes, a new one follows the new output.
    private func reopen() {
        closeDevice()
        try? open()
    }
    private func closeDevice() {
        if aggregate != kAudioObjectUnknown {
            if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        proc = nil; aggregate = AudioObjectID(kAudioObjectUnknown)
    }

    func stop() {
        if let outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, outputListener)
            self.outputListener = nil
        }
        control.sync { closeDevice() }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        writer?.close()
        view?.unsafeMutablePointer.deallocate(); view = nil
    }

    /// How many input streams a device has of its own, each a buffer in what the aggregate reads.
    private static func inputBuffers(of uid: String) -> Int {
        var translate = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString, device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let found = withUnsafeMutablePointer(to: &cfUID) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<CFString>.size), $0, &size, &device) }
        guard found == noErr, device != kAudioObjectUnknown else { return 0 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr, bytes > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, list) == noErr else { return 0 }
        return Int(list.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
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
