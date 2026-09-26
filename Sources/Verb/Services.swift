import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CryptoKit
import IOKit
import Security
import VerbCore
import VerbEngine

enum Secrets {
    private static var service = "app.verb.dictation"
    /// A profile of its own (`--data-dir`) keeps its keys apart from yours.
    static func useProfile(_ folder: URL) {
        service = "app.verb.dictation.profile." + SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ name: String) -> String { value(name, service: service) ?? "" }
    private static func item(_ name: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }
    private static func value(_ name: String, service: String) -> String? {
        var search = item(name, service: service); search[kSecReturnData as String] = true; search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, name: String) throws {
        let query = item(name, service: service)
        if value.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw VerbError("Keychain could not remove this key.") }; return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VerbError("Keychain could not save this key.") }
        } else if status != errSecSuccess { throw VerbError("Keychain could not update this key.") }
    }
}

@MainActor final class LocalWriterProcess {
    private var process: Process?
    /// An engine a previous run of Verb left behind, taken over so it stops with this one.
    private var adopted: pid_t?
    private let paths: DataPaths
    private let client = ModelClient()
    init(paths: DataPaths) { self.paths = paths }
    /// Where the engine's process number is noted, so one left behind by a crash is known as Verb's.
    private var pidFile: URL { paths.root.appendingPathComponent("writer.pid") }
    var available: Bool { executable != nil }
    private var executable: URL? {
        ["/Applications/Ollama.app/Contents/Resources/ollama", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    func start() async throws {
        if (try? await client.localModels()) != nil {
            if process == nil, adopted == nil, let noted = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), kill(noted, 0) == 0 { adopted = noted }
            return
        }
        if process?.isRunning == true { throw VerbError("The local writing engine is still starting. Try again in a moment.") }
        guard let executable else { throw VerbError("Install Ollama to run a local writing model, or choose a hosted model.") }
        let process = Process(); process.executableURL = executable; process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11435"
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_MODELS"] = paths.root.appendingPathComponent("WriterModels").path
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        for _ in 0..<60 {
            if (try? await client.localModels()) != nil { return }
            guard process.isRunning else { throw VerbError("The local writing engine stopped unexpectedly.") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VerbError("The local writing engine did not start. Check Ollama is installed correctly.")
    }
    func stop() {
        if process?.isRunning == true { process?.terminate() }
        if let adopted { kill(adopted, SIGTERM) }
        process = nil; adopted = nil
        try? FileManager.default.removeItem(at: pidFile)
    }
    /// The engine Verb started or took over, if it runs.
    var pid: pid_t? { process?.isRunning == true ? process?.processIdentifier : adopted }
}

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String; let name: String; let deviceID: AudioDeviceID
    var transport: UInt32 = 0
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}
enum Microphones {
    /// The input macOS uses when none is chosen.
    static func systemDefault() -> MicrophoneDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return list().first { $0.deviceID == device }
    }
    /// The microphone a dictation would use: the chosen one, or the system's, or the Mac's own
    /// instead of Bluetooth headphones, which switch to call quality while their mic is open.
    static func effective(_ chosen: String, preferBuiltIn: Bool) -> MicrophoneDevice? {
        let devices = list()
        if !chosen.isEmpty { return devices.first { $0.id == chosen } }
        let system = systemDefault()
        // With the lid closed the Mac's own microphone hears nothing: the headset it is.
        if preferBuiltIn, system?.isBluetooth == true, !lidClosed, let builtIn = devices.first(where: \.isBuiltIn) { return builtIn }
        return system
    }
    /// Whether the laptop's lid is closed, as with an external display.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }
    static func list() -> [MicrophoneDevice] {
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
            return MicrophoneDevice(id: uid, name: string(device, kAudioObjectPropertyName) ?? "Microphone", deviceID: device, transport: transport)
        }
    }
}

/// A moment the voice-activity detector noticed, with the audio needed to check the words.
struct SpeechMoment: Sendable {
    let event: VoiceActivity.Event
    /// The stream up to this moment: the utterance so far, or the last few seconds before a
    /// pause, words said earlier included. Empty when speech has only just begun.
    let window: [Float]
    /// Where the window starts in the stream.
    let windowStart: Int
    /// The utterance alone. A wake check reads this, because the phrase must open it.
    var utterance: [Float] {
        guard case .ended(let segment) = event else { return window }
        return Array(window.dropFirst(max(0, segment.start - windowStart)))
    }
}

/// Turns the microphone into 16 kHz mono on its own queue. It always feeds the voice-activity
/// detector and a ring of the last few seconds, both kept in memory only. Audio reaches the
/// disk only while a dictation records.
private final class AudioSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.verb.audio-write", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 24)
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let meter: @Sendable ([Float]) -> Void
    private let heard: @Sendable (SpeechMoment) -> Void
    // Everything below belongs to `queue`.
    private var file: AVAudioFile?
    private var error: Error?
    private var voicedSeconds: Double = 0
    private var recorded: Int64 = 0
    /// The loudest sample of the dictation: next to nothing means the microphone gave silence.
    private var peak: Float = 0
    private var ring = SampleRing(capacity: 16000 * 12)
    private var activity = VoiceActivity()
    /// The last two minutes of the dictation, kept in memory for the live preview; the file has
    /// all of it. `takeDropped` counts the samples let go from the front, and `takeStart` is
    /// where the dictation began in the stream.
    private var take: [Float] = []
    private var takeDropped = 0
    private var takeStart = 0
    private static let takeKept = 16000 * 120
    /// The longest stretch a voice check looks at: enough for "…ci vediamo domani, ehi Verb stop".
    private static let checkWindow = 16000 * 4

    init(input: AVAudioFormat, meter: @escaping @Sendable ([Float]) -> Void, heard: @escaping @Sendable (SpeechMoment) -> Void) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input, to: format) else { throw VerbError("This microphone's audio format is unsupported.") }
        self.format = format; self.converter = converter; self.meter = meter; self.heard = heard
    }
    func consume(_ input: AVAudioPCMBuffer) {
        guard slots.wait(timeout: .now()) == .success else {
            // A recording needs every buffer; listening can miss one.
            queue.async { if self.file != nil { self.error = VerbError("Audio storage could not keep up. Check disk space and retry with a shorter recording.") } }
            return
        }
        // Copy before leaving the render callback: AVAudioEngine reuses the incoming buffer.
        guard let copied = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { slots.signal(); return }
        copied.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for i in 0..<min(source.count, destination.count) {
            if let src = source[i].mData, let dst = destination[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)) }
        }
        queue.async { [self] in
            defer { slots.signal() }
            let capacity = AVAudioFrameCount(ceil(Double(copied.frameLength) * 16000 / copied.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false, conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return copied
            }
            if let conversionError { if file != nil { error = conversionError }; return }
            let count = Int(output.frameLength)
            guard count > 0, let channel = output.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            if file != nil, error == nil {
                do { try file?.write(from: output) } catch { self.error = error }
                take.append(contentsOf: chunk)
                if take.count > Self.takeKept + 16000 * 10 { let excess = take.count - Self.takeKept; take.removeFirst(excess); takeDropped += excess }
                peak = max(peak, chunk.reduce(0) { max($0, abs($1)) })
                let rms = Self.rms(chunk[...])
                if rms > 0.003 { voicedSeconds += Double(count) / 16000 }
                recorded += Int64(count)
                // A level for every 10 ms, so the stroke can move at the display's rate though audio arrives in 100 ms pieces.
                meter(stride(from: 0, to: count, by: 160).map { start in Self.loudness(Self.rms(chunk[start..<min(start + 160, count)])) })
            }
            ring.append(chunk)
            for event in activity.process(chunk) { report(event) }
        }
    }
    private func report(_ event: VoiceActivity.Event) {
        switch event {
        case .started(let position): heard(SpeechMoment(event: event, window: [], windowStart: position))
        case .continuing(let segment):
            let start = max(segment.start, ring.start)
            heard(SpeechMoment(event: event, window: ring.samples(from: start, to: segment.end), windowStart: start))
        case .ended(let segment):
            // A few seconds with what came before: a short "Ehi Verb stop" is heard better in context.
            let start = max(segment.end - Self.checkWindow, ring.start)
            heard(SpeechMoment(event: event, window: ring.samples(from: start, to: segment.end), windowStart: start))
        }
    }
    /// Speech from a whisper to a raised voice, from 0 to 1.
    private static func loudness(_ rms: Float) -> Float { min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 50)) }
    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
    /// Starts writing to `url`. With a position, the file begins at that point of the stream,
    /// taken from the ring, so the words said while "Ehi Verb" was being recognized are kept.
    func beginRecording(url: URL, from position: Int?) throws {
        try queue.sync {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            // What you said: readable by you only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil; voicedSeconds = 0; recorded = 0; peak = 0
            let earlier = position.map { ring.samples(from: $0, to: ring.end) } ?? []
            take = earlier; takeDropped = 0; takeStart = ring.end - earlier.count
            if !earlier.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(earlier.count)), let channel = buffer.floatChannelData?[0] {
                buffer.frameLength = AVAudioFrameCount(earlier.count)
                earlier.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: earlier.count) }
                try file.write(from: buffer)
                recorded = Int64(earlier.count)
                peak = earlier.reduce(0) { max($0, abs($1)) }
                for start in stride(from: 0, to: earlier.count, by: 320) where Self.rms(earlier[start..<min(start + 320, earlier.count)]) > 0.003 {
                    voicedSeconds += Double(min(320, earlier.count - start)) / 16000
                }
            }
            self.file = file
        }
    }
    /// The recorded samples from `offset` on, and the length of the take.
    func take(from offset: Int) -> (samples: [Float], end: Int) {
        queue.sync {
            let end = takeDropped + take.count, index = max(0, offset - takeDropped)
            return (index < take.count ? Array(take[index...]) : [], end)
        }
    }
    /// Where a stream position falls in the take.
    func takeOffset(ofStream position: Int) -> Int { queue.sync { max(0, position - takeStart) } }
    func endRecording() throws -> (Double, Double, Float) {
        try queue.sync {
            file = nil
            take = []; takeDropped = 0
            // What was said during the dictation, its closing command included, never counts afterwards.
            activity.restart()
            if let error { self.error = nil; throw error }
            return (Double(recorded) / 16000, voicedSeconds, peak)
        }
    }
}

/// The microphone. It records dictations to disk and, with voice activation on, keeps
/// listening between them in memory only, so "Ehi Verb" can start one without losing the
/// words that follow it.
@MainActor final class Recorder {
    private var engine: AVAudioEngine?
    private var sink: AudioSink?
    private var device: String?
    private var observer: NSObjectProtocol?
    private var recording = false
    /// Whether the microphone stays open between dictations.
    private(set) var listening = false
    var onLevel: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    var onSpeech: ((SpeechMoment) -> Void)?
    /// With the system microphone chosen, use the Mac's own rather than Bluetooth headphones.
    var preferBuiltIn = true
    var running: Bool { engine?.isRunning == true }
    /// The name of the microphone in use, for messages.
    private(set) var inputName = ""

    /// Opens the microphone between dictations, or reopens it after macOS stopped it for
    /// sleep or a device change. Calling it again costs nothing.
    func listen(deviceID: String) throws { listening = true; try open(deviceID) }
    func stopListening() { listening = false; if !recording { close() } }

    /// Starts a dictation's file. With `from`, the file begins at that point of the stream.
    func start(url: URL, deviceID: String, from position: Int? = nil) throws {
        try open(deviceID)
        guard let sink else { throw VerbError("No microphone is available.") }
        try sink.beginRecording(url: url, from: position)
        recording = true
    }
    func stop() throws -> (duration: Double, voiced: Double, peak: Float) {
        defer { recording = false; if !listening { close() } }
        return try sink?.endRecording() ?? (0, 0, 0)
    }
    /// What the current dictation has recorded from `offset` on, for the live preview.
    func take(from offset: Int) -> (samples: [Float], end: Int) { sink?.take(from: offset) ?? ([], 0) }
    func takeOffset(ofStream position: Int) -> Int { sink?.takeOffset(ofStream: position) ?? 0 }

    private func open(_ deviceID: String) throws {
        // The system microphone may be headphones, where the Mac's own is kept instead.
        let chosen = Microphones.effective(deviceID, preferBuiltIn: preferBuiltIn)
        let key = deviceID.isEmpty ? "system:" + (chosen?.id ?? "") : deviceID
        if running, device == key { return }
        guard !recording else { return }
        close()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceID.isEmpty || chosen?.id != Microphones.systemDefault()?.id {
            guard var device = chosen?.deviceID, let unit = input.audioUnit else { throw VerbError("The selected microphone is disconnected. Choose another input in Settings.") }
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw VerbError("Could not select that microphone.") }
        }
        inputName = chosen?.name ?? ""
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VerbError("No microphone is available.") }
        let sink = try AudioSink(input: format, meter: { [weak self] values in Task { @MainActor in self?.onLevel?(values) } },
                                 heard: { [weak self] moment in Task { @MainActor in self?.onSpeech?(moment) } })
        // macOS delivers an input tap's audio every 100 ms at best, whatever size is asked for.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in sink.consume(buffer) }
        do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine; self.sink = sink; device = key
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in Task { @MainActor in self?.configurationChanged() } }
    }
    /// A device came or went. A dictation ends with what it has; listening resumes on the new input.
    private func configurationChanged() {
        if recording { onInterruption?() }
        guard !recording else { return }
        let current = device.map { $0.hasPrefix("system:") ? "" : $0 } ?? ""
        close()
        if listening { try? open(current) }
    }
    private func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil; sink = nil; device = nil
    }
}
