import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CryptoKit
import IOKit
import os
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
/// disk only while a dictation records. Of a device's several inputs it takes the loudest, so
/// a microphone on the second input of an audio interface is heard.
private final class AudioSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.verb.audio-write", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 24)
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var format: AVAudioFormat { Self.format }
    private let meter: @Sendable ([Float]) -> Void
    private let heard: @Sendable (SpeechMoment) -> Void
    /// Called once when the disk stops taking a dictation, so it can end at once.
    private let failed: @Sendable () -> Void
    // Everything below belongs to `queue`.
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var error: Error?
    /// Samples of the dictation a full queue let go, at 16 kHz.
    private var lost = 0
    private var voicedSeconds: Double = 0
    private var recorded: Int64 = 0
    /// The loudest sample of the dictation: next to nothing means the microphone gave silence.
    private var peak: Float = 0
    /// Pieces of audio the microphone has delivered, to tell a device that sends nothing.
    private var arrived = 0
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

    init(meter: @escaping @Sendable ([Float]) -> Void, heard: @escaping @Sendable (SpeechMoment) -> Void, failed: @escaping @Sendable () -> Void) {
        self.meter = meter; self.heard = heard; self.failed = failed
    }
    /// The microphone's format: the engine started, or started again on another device.
    func use(input: AVAudioFormat) throws {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: mono, to: format) else { throw VerbError("This microphone's audio format is unsupported.") }
        queue.sync { self.converter = converter }
    }
    /// Where the stream is now, to start a dictation's file at this point.
    var position: Int { queue.sync { ring.end } }
    var received: Int { queue.sync { arrived } }

    func consume(_ input: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        guard slots.wait(timeout: .now()) == .success else {
            // A dictation needs every buffer; what a slow disk makes it miss is counted and said at the end.
            let missed = Int(Double(frames) * 16000 / input.format.sampleRate)
            queue.async { if self.file != nil { self.lost += missed } }
            return
        }
        // Copy before leaving the audio thread: the microphone reuses the incoming buffer. Of
        // several channels, the loudest one, where the voice is.
        guard frames > 0, let channels = input.floatChannelData,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.format.sampleRate, channels: 1, interleaved: false),
              let copied = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength), let target = copied.floatChannelData?[0] else { slots.signal(); return }
        copied.frameLength = input.frameLength
        var loudest = 0
        if input.format.channelCount > 1 {
            var best: Float = -1
            for channel in 0..<Int(input.format.channelCount) {
                var energy: Float = 0
                for index in stride(from: 0, to: frames, by: 4) { energy += channels[channel][index] * channels[channel][index] }
                if energy > best { best = energy; loudest = channel }
            }
        }
        target.update(from: channels[loudest], count: frames)
        queue.async { [self] in
            defer { slots.signal() }
            arrived += 1
            guard let converter else { return }
            let capacity = AVAudioFrameCount(ceil(Double(copied.frameLength) * 16000 / copied.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false, conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return copied
            }
            if let conversionError {
                if file != nil, error == nil { error = conversionError; failed() }
                return
            }
            let count = Int(output.frameLength)
            guard count > 0, let channel = output.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            if file != nil, error == nil {
                do {
                    try file?.write(from: output)
                    take.append(contentsOf: chunk)
                    if take.count > Self.takeKept + 16000 * 10 { let excess = take.count - Self.takeKept; take.removeFirst(excess); takeDropped += excess }
                    peak = max(peak, chunk.reduce(0) { max($0, abs($1)) })
                    let rms = Self.rms(chunk[...])
                    if rms > 0.003 { voicedSeconds += Double(count) / 16000 }
                    recorded += Int64(count)
                    // A level for every 10 ms, so the stroke can move at the display's rate though audio arrives in 100 ms pieces.
                    meter(stride(from: 0, to: count, by: 160).map { start in Self.loudness(Self.rms(chunk[start..<min(start + 160, count)])) })
                } catch { self.error = error; failed() }
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
    /// taken from the ring: the words said while "Ehi Verb" was being recognized, or since the
    /// dictation keys went down, are kept.
    func beginRecording(url: URL, from position: Int?) throws {
        try queue.sync {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            // What you said: readable by you only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil; lost = 0; voicedSeconds = 0; recorded = 0; peak = 0
            let earlier = position.map { ring.samples(from: max($0, ring.start), to: ring.end) } ?? []
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
    /// Closes the file, with the last moment the converter still held. What was recorded stays
    /// even when the disk gave up partway; `problem` says so, and how much a slow disk let go.
    func endRecording() -> (duration: Double, voiced: Double, peak: Float, problem: String?) {
        queue.sync {
            if let file, error == nil, let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
                var flushError: NSError?
                converter.convert(to: output, error: &flushError) { _, status in status.pointee = .endOfStream; return nil }
                if flushError == nil, output.frameLength > 0, (try? file.write(from: output)) != nil { recorded += Int64(output.frameLength) }
            }
            converter?.reset()
            file = nil
            take = []; takeDropped = 0
            // What was said during the dictation, its closing command included, never counts afterwards.
            activity.restart()
            var problem: String?
            if error != nil { problem = "The disk stopped taking the recording, so it ended early. What you said until then is kept. Check the free space." }
            else if lost >= 8000 { problem = "The disk couldn’t keep up: about \(max(1, Int((Double(lost) / 16000).rounded()))) s of this recording are missing." }
            error = nil; lost = 0
            return (Double(recorded) / 16000, voicedSeconds, peak, problem)
        }
    }
}

/// The microphone. It records dictations to disk and, with voice activation on, keeps
/// listening between them in memory only, so "Ehi Verb" can start one without losing the
/// words that follow it.
@MainActor final class Recorder {
    private var input: MicrophoneInput?
    private var sink: AudioSink?
    /// What is open: the chosen microphone, or the system's, or a stand-in, with its identifier.
    private var device: String?
    /// The microphone as chosen in Settings, empty for the system's.
    private var choice = ""
    private var recording = false
    /// Whether the microphone stays open between dictations.
    private(set) var listening = false
    /// Opened when the dictation keys went down, before the dictation itself starts.
    private var prepared = false
    private var restarts = RestartBudget()
    private var soundCheck: Task<Void, Never>?
    private static let log = Logger(subsystem: "app.verb.dictation", category: "audio")
    var onLevel: (([Float]) -> Void)?
    var onInterruption: (() -> Void)?
    var onSpeech: ((SpeechMoment) -> Void)?
    /// The disk stopped taking the recording: the dictation ends now, with what it has.
    var onFailure: (() -> Void)?
    /// Another microphone took over, mid-dictation or because the chosen one is missing: its name.
    var onFallback: ((String) -> Void)?
    /// The microphone delivered no sound at all once the dictation began.
    var onNoSound: (() -> Void)?
    /// A microphone opened for a dictation took this long, in seconds, to send its first sound.
    var onOpened: ((String, String, Double) -> Void)?
    /// The device opened last, by its identifier.
    private var openedID = ""
    /// With the system microphone chosen, use the Mac's own rather than Bluetooth headphones.
    var preferBuiltIn = true
    var running: Bool { input != nil }
    /// The name of the microphone in use, for messages.
    private(set) var inputName = ""
    /// Where the microphone's stream is now; a dictation can start its file from here.
    var position: Int { sink?.position ?? 0 }

    /// Opens the microphone between dictations, or reopens it after macOS stopped it for
    /// sleep or a device change. Calling it again costs nothing.
    func listen(deviceID: String) throws { listening = true; try open(deviceID) }
    func stopListening() { listening = false; if !recording && !prepared { close() } }
    /// Opens the microphone as the dictation keys go down, so the first word is heard while the
    /// short wait that tells a dictation from a shortcut runs. Bluetooth headphones wait for the
    /// dictation itself: opening their microphone switches them to call quality, for every press
    /// of the keys.
    func prepare(deviceID: String) {
        guard !recording else { return }
        if !running, Microphones.pick(deviceID, preferBuiltIn: preferBuiltIn)?.device.isBluetooth != false { return }
        prepared = (try? open(deviceID)) != nil
    }
    /// The keys were for something else.
    func release() {
        guard prepared else { return }
        prepared = false
        if !recording && !listening { close() }
    }

    /// Starts a dictation's file. With `from`, the file begins at that point of the stream.
    func start(url: URL, deviceID: String, from position: Int? = nil) throws {
        let wasOpen = running, asked = Date()
        try open(deviceID)
        guard let sink else { throw VerbError("No microphone is available.") }
        try sink.beginRecording(url: url, from: position)
        recording = true; prepared = false; restarts.reset()
        checkForSound(sink)
        // Opened now rather than already open: how long it takes to send its first sound.
        if !wasOpen {
            let id = openedID, name = inputName, before = sink.received
            Task { [weak self] in
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self, self.sink === sink else { return }
                    if sink.received > before { self.onOpened?(id, name, Date().timeIntervalSince(asked)); return }
                }
            }
        }
    }
    func stop() -> (duration: Double, voiced: Double, peak: Float, problem: String?) {
        defer { recording = false; soundCheck?.cancel(); soundCheck = nil; if !listening { close() } }
        return sink?.endRecording() ?? (0, 0, 0, nil)
    }
    /// What the current dictation has recorded from `offset` on, for the live preview.
    func take(from offset: Int) -> (samples: [Float], end: Int) { sink?.take(from: offset) ?? ([], 0) }
    func takeOffset(ofStream position: Int) -> Int { sink?.takeOffset(ofStream: position) ?? 0 }

    private func open(_ deviceID: String) throws {
        // The system microphone may be headphones, where the Mac's own is kept instead. A chosen
        // microphone that is missing gives way to the system's, and says so.
        guard let pick = Microphones.pick(deviceID, preferBuiltIn: preferBuiltIn) else { throw VerbError("No microphone is available.") }
        let key = deviceID.isEmpty ? "system:" + pick.device.id : pick.standIn ? "instead:" + pick.device.id : deviceID
        if running, device == key { return }
        guard !recording else { return }
        close()
        let sink = AudioSink(meter: { [weak self] values in Task { @MainActor in self?.onLevel?(values) } },
                             heard: { [weak self] moment in Task { @MainActor in self?.onSpeech?(moment) } },
                             failed: { [weak self] in Task { @MainActor in self?.onFailure?() } })
        try attach(pick.device, to: sink)
        self.sink = sink; device = key; choice = deviceID; restarts.reset()
        if pick.standIn { onFallback?(pick.device.name) }
    }
    /// Opens `microphone` and sends what it hears to `sink`.
    private func attach(_ microphone: MicrophoneDevice, to sink: AudioSink) throws {
        let input = try MicrophoneInput(microphone) { buffer in sink.consume(buffer) }
        try sink.use(input: input.format)
        input.onChange = { [weak self] change in MainActor.assumeIsolated { self?.changed(change) } }
        try input.start()
        self.input = input; inputName = microphone.name; openedID = microphone.id
    }
    /// The device went away or changed its format, and its input stopped. A dictation goes on
    /// into the same file: on the same microphone if it is still there, or on the one Verb would
    /// pick now, which is then named. A device that keeps changing is given up on, and the
    /// dictation ends with what it has. Listening resumes on whichever microphone is right now.
    private func changed(_ change: MicrophoneInput.Change) {
        let previous = input?.device
        input = nil
        guard let sink else { return }
        if recording {
            guard restarts.allow(at: Date().timeIntervalSinceReferenceDate) else {
                Self.log.error("Microphone keeps changing: dictation ended")
                onInterruption?(); return
            }
            if change == .format, let previous, let same = Microphones.list().first(where: { $0.deviceID == previous.deviceID }),
               (try? attach(same, to: sink)) != nil { return }
            if let pick = Microphones.pick(choice, preferBuiltIn: preferBuiltIn), (try? attach(pick.device, to: sink)) != nil {
                if pick.device.deviceID != previous?.deviceID { onFallback?(pick.device.name) }
                return
            }
            onInterruption?()
            return
        }
        close()
        if listening { try? open(choice) }
    }
    /// A device can open and send nothing at all. Said once, a moment after the dictation began.
    private func checkForSound(_ sink: AudioSink) {
        soundCheck?.cancel()
        let before = sink.received
        soundCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.recording, self.sink === sink, sink.received == before else { return }
            Self.log.error("Microphone sent no sound")
            self.onNoSound?()
        }
    }
    private func close() {
        input?.stop(); input = nil; sink = nil; device = nil; prepared = false
    }
}
