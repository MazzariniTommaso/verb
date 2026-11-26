import Foundation
import CryptoKit
import MLX
import MLXAudioCore
import MLXAudioSTT
import VerbCore

/// Loads any speech model the MLX library runs from a folder on disk, by the family its config.json
/// names. Nothing is fetched here: a folder holds a complete model or fails to load.
public enum SpeechModels {
    public static func architecture(of folder: URL) throws -> SpeechArchitecture {
        let data = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        guard let found = SpeechArchitecture.detect(config: data) else { throw VerbError("This folder holds no speech model Verb can run.") }
        return found
    }

    public static func load(_ folder: URL) async throws -> SpeechRunner {
        let architecture = try architecture(of: folder)
        let model: any STTGenerationModel
        switch architecture {
        case .parakeet: model = try ParakeetModel.fromDirectory(folder)
        case .canary: model = try await CanaryModel.fromModelDirectory(folder)
        case .nemotron: model = try NemotronASRModel.fromDirectory(folder)
        case .qwen3ASR: model = try await Qwen3ASRModel.fromModelDirectory(folder)
        case .cohere: model = try CohereTranscribeModel.fromDirectory(folder)
        case .whisper:
            // Without a tokenizer in the folder the library fetches one from the network.
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) else { throw VerbError("This Whisper model is missing its tokenizer. Install it again.") }
            model = try await WhisperModel.fromDirectory(folder)
        case .voxtralRealtime: model = try VoxtralRealtimeModel.fromDirectory(folder)
        case .graniteSpeech: model = try await GraniteSpeechModel.fromModelDirectory(folder)
        case .glmASR: model = try await GLMASRModel.fromModelDirectory(folder)
        case .fireRedASR2: model = try FireRedASR2Model.fromDirectory(folder)
        case .senseVoice: model = try SenseVoiceModel.fromDirectory(folder)
        case .mossTranscribeDiarize: model = try await MossTranscribeDiarizeModel.fromModelDirectory(folder)
        case .moonshine: model = try await MoonshineModel.fromModelDirectory(folder)
        case .wav2vec2: model = try Wav2Vec2CTCModel.fromModelDirectory(folder)
        case .lasrCTC: model = try LasrCTCModel.fromModelDirectory(folder)
        }
        return SpeechRunner(model: model, architecture: architecture)
    }
}

/// A loaded model, decoded the way Verb decodes dictations: windows of at most 28 seconds cut near
/// quiet points, greedy decoding, and the language in the form the family expects.
public final class SpeechRunner {
    public let architecture: SpeechArchitecture
    private let model: any STTGenerationModel
    init(model: any STTGenerationModel, architecture: SpeechArchitecture) { self.model = model; self.architecture = architecture }

    /// `language` is an ISO 639-1 code, or nil for the model to decide. The detected language is
    /// returned as the model names it, when it says.
    public func transcribe(_ samples: [Float], language: String?, vocabulary: [String] = []) async throws -> (text: String, language: String?) {
        var texts: [String] = [], detected: String?
        for range in SpeechChunking.ranges(samples: samples, sampleRate: 16000) {
            try Task.checkCancellation()
            let output = try await decode(Array(samples[range]), language: language, vocabulary: vocabulary)
            texts.append(TextRules.tidy(output.text)); detected = output.language ?? detected
        }
        Memory.clearCache()
        return (TextRules.tidy(texts.joined(separator: " ")), detected)
    }

    private func decode(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> STTOutput {
        let audio = MLXArray(samples), hint = architecture.hint(for: language)
        if let qwen = model as? Qwen3ASRModel, !vocabulary.isEmpty {
            var final: STTOutput?
            for try await event in qwen.generateStream(audio: audio, maxTokens: 1024, temperature: 0, context: vocabulary.prefix(100).joined(separator: ", "), language: hint, chunkDuration: 30) {
                try Task.checkCancellation()
                if case .result(let output) = event { final = output }
            }
            guard let final else { throw VerbError("The MLX speech model returned no text.") }
            return final
        }
        // Each family's own defaults, with greedy decoding and room for a full window of speech.
        let base = model.defaultGenerationParameters
        let parameters = STTGenerateParameters(maxTokens: base.maxTokens > 0 ? min(base.maxTokens, 1024) : base.maxTokens, temperature: 0, topP: base.topP, topK: base.topK, verbose: false, language: hint, chunkDuration: min(base.chunkDuration, 30), minChunkDuration: base.minChunkDuration, repetitionPenalty: base.repetitionPenalty, repetitionContextSize: base.repetitionContextSize, kvBits: base.kvBits, kvGroupSize: base.kvGroupSize, quantizedKVStart: base.quantizedKVStart)
        let output = model.generate(audio: audio, generationParameters: parameters)
        try Task.checkCancellation()
        return output
    }
}

/// Installs a Hugging Face model repository into a folder for offline use. The revision is resolved
/// to a commit once, each file is checked against the hash the repository publishes, and a record of
/// what was installed is written last, so a folder with a record is complete.
public enum SpeechModelInstaller {
    public struct Record: Codable, Equatable, Sendable {
        public let repository: String
        public let revision: String
        public let architecture: SpeechArchitecture
        public let files: [HubFile]
        /// Where files the repository lacks came from, such as a Whisper tokenizer.
        public let companion: String?
        public init(repository: String, revision: String, architecture: SpeechArchitecture, files: [HubFile], companion: String?) {
            self.repository = repository; self.revision = revision; self.architecture = architecture; self.files = files; self.companion = companion
        }
    }
    public static let recordName = ".verb-model.json"

    /// The record of a complete install, or nil when a file is missing or has the wrong size.
    public static func record(in folder: URL) -> Record? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(recordName)), let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.files.allSatisfy { file in
            (try? folder.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) == file.size } ?? false
        } ? record : nil
    }

    /// `repository` is "owner/name", optionally followed by "@revision".
    public static func install(_ repository: String, into folder: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> Record {
        let parts = repository.split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts[0], wanted = parts.count > 1 ? parts[1] : "main"
        guard SpeechModelFiles.isRepository(name), wanted.range(of: #"^[A-Za-z0-9._\-/]+$"#, options: .regularExpression) != nil else { throw VerbError("Enter a Hugging Face model as owner/name.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(recordName))
        let (revision, files) = try await listing(name, revision: wanted)
        guard let configFile = files.first(where: { $0.path == "config.json" }), files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw VerbError("This repository has no MLX weights. Choose one that ships safetensors.") }
        // The config comes first, so an unsupported family fails before gigabytes arrive.
        try await fetch(configFile, from: name, revision: revision, into: folder)
        let config = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        guard let architecture = SpeechArchitecture.detect(config: config) else { throw VerbError("Verb can't run this kind of speech model yet.") }
        var installed = [configFile]
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size }), counter = ProgressCounter()
        for file in files where file.path != "config.json" {
            try Task.checkCancellation()
            let done = counter.value
            try await fetch(file, from: name, revision: revision, into: folder) { received in
                progress(min(0.97, Double(done + received) / Double(total)), "Downloading \(file.path)…")
            }
            counter.add(file.size); installed.append(file)
        }
        var companion: String?
        if architecture == .whisper, !files.contains(where: { $0.path == "tokenizer.json" }) {
            // MLX Whisper conversions ship weights only; the tokenizer lives with OpenAI's originals.
            let source = whisperTokenizerRepository(config: config)
            let (sourceRevision, sourceFiles) = try await listing(source, revision: "main")
            let tokenizerNames: Set<String> = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt", "normalizer.json"]
            for file in sourceFiles where tokenizerNames.contains(file.path) || (file.path == "generation_config.json" && !files.contains(where: { $0.path == file.path })) {
                try await fetch(file, from: source, revision: sourceRevision, into: folder); installed.append(file)
            }
            companion = "\(source)@\(sourceRevision)"
        }
        let record = Record(repository: name, revision: revision, architecture: architecture, files: installed, companion: companion)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent(recordName), options: .atomic)
        progress(1, "Model ready offline")
        return record
    }

    static func whisperTokenizerRepository(config: Data) -> String {
        let values = (try? JSONSerialization.jsonObject(with: config) as? [String: Any]) ?? [:]
        switch values["vocab_size"] as? Int ?? values["n_vocab"] as? Int ?? 51866 {
        case 51864: return "openai/whisper-medium.en"
        case 51865: return "openai/whisper-medium"
        default: return "openai/whisper-large-v3"
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.urlCache = nil; configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// The commit a revision points to, and the files Verb needs at that commit.
    private static func listing(_ repository: String, revision: String) async throws -> (String, [HubFile]) {
        struct Info: Decodable { let sha: String }
        let info: Info = try JSONDecoder().decode(Info.self, from: try await get("https://huggingface.co/api/models/\(repository)/revision/\(revision)"))
        let files = SpeechModelFiles.needed(try SpeechModelFiles.parseTree(try await get("https://huggingface.co/api/models/\(repository)/tree/\(info.sha)")))
        return (info.sha, files)
    }

    private static func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw VerbError("Enter a Hugging Face model as owner/name.") }
        let (data, response) = try await session.data(from: url)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw VerbError("This model asks you to accept its terms on Hugging Face. Choose an open copy of it.")
        case 404: throw VerbError("Hugging Face has no model with this name.")
        default: throw VerbError("Hugging Face didn't answer. Try again in a moment.")
        }
    }

    private static func fetch(_ file: HubFile, from repository: String, revision: String, into folder: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let destination = folder.appendingPathComponent(file.path)
        if try matches(destination, file) { return }
        let configuration = URLSessionConfiguration.ephemeral
        // Hours: multi-gigabyte weights take that long on a slow connection.
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 24 * 3600
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
        let (temporary, response) = try await SpeechDownload.fetch(url, configuration: configuration, resumeFile: folder.appendingPathComponent(file.path.replacingOccurrences(of: "/", with: "_") + ".resume"), progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if [401, 403].contains(response.statusCode) { throw VerbError("This model asks you to accept its terms on Hugging Face. Choose an open copy of it.") }
        guard [200, 206].contains(response.statusCode), try matches(temporary, file) else { throw VerbError("A model file failed its integrity check. Retry the download.") }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Size first, then the hash the repository publishes: SHA-256 for LFS files, Git's blob hash otherwise.
    static func matches(_ url: URL, _ file: HubFile) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        if let expected = file.sha256 {
            var hash = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
        }
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(file.size)\0".utf8))
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.gitSHA1
    }
}

/// Bytes completed so far, shared with the progress callbacks of each file.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock(); private var total: Int64 = 0
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return total }
    func add(_ bytes: Int64) { lock.lock(); total += bytes; lock.unlock() }
}

/// MLX's memory counters, to measure what a model costs.
public enum SpeechMemory {
    public static var peak: Int64 { Int64(Memory.peakMemory) }
    public static func resetPeak() { Memory.peakMemory = 0 }
    /// What MLX holds now: in arrays in use, and kept aside for reuse.
    public static var active: Int64 { Int64(Memory.activeMemory) }
    public static var cache: Int64 { Int64(Memory.cacheMemory) }
}
