import Foundation

/// The speech model families the MLX library runs, as a model folder's config.json names them.
/// A family the library adds becomes usable with one case here and one line in the engine's loader;
/// models of a known family need no code at all.
public enum SpeechArchitecture: String, Codable, CaseIterable, Sendable {
    case parakeet, canary, nemotron = "nemotron_asr", qwen3ASR = "qwen3_asr", cohere = "cohere_asr", whisper
    case voxtralRealtime = "voxtral_realtime", graniteSpeech = "granite_speech", glmASR = "glmasr", fireRedASR2 = "fireredasr2"
    case senseVoice = "sensevoice", mossTranscribeDiarize = "moss_transcribe_diarize", moonshine, wav2vec2, lasrCTC = "lasr_ctc"

    /// The library's own names and aliases for each family.
    public init?(modelType: String) {
        switch modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "parakeet": self = .parakeet
        case "canary": self = .canary
        case "nemotron", "nemotron_asr": self = .nemotron
        case "qwen3_asr": self = .qwen3ASR
        case "cohere", "cohere_asr": self = .cohere
        case "whisper": self = .whisper
        case "voxtral", "voxtral_realtime": self = .voxtralRealtime
        case "granite_speech": self = .graniteSpeech
        case "glm", "glmasr": self = .glmASR
        case "firered", "fire_red", "fireredasr2": self = .fireRedASR2
        case "sensevoice": self = .senseVoice
        case "moss_transcribe_diarize": self = .mossTranscribeDiarize
        case "moonshine": self = .moonshine
        case "wav2vec", "wav2vec2", "mms": self = .wav2vec2
        case "lasr", "lasr_ctc": self = .lasrCTC
        default: return nil
        }
    }

    /// Reads config.json. NeMo conversions such as Parakeet and Canary carry no model type, only the
    /// NeMo class they came from.
    public static func detect(config data: Data) -> SpeechArchitecture? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["model_type", "architecture", "model_version"] {
            if let name = config[key] as? String, let found = SpeechArchitecture(modelType: name) { return found }
        }
        guard let target = (config["target"] as? String)?.lowercased(), target.hasPrefix("nemo.collections.asr") else { return nil }
        if target.contains("aed_multitask") { return .canary }
        if target.contains("prompt") { return .nemotron }
        if target.contains("rnnt") || target.contains("ctc") { return .parakeet }
        return nil
    }

    /// What the model does with a language.
    public enum LanguageUse: String, Codable, Sendable {
        /// It detects the language and takes no hint.
        case detects
        /// It detects the language, and a hint makes it surer.
        case hinted
        /// It must be told; without a language it assumes English.
        case required
        /// The language is the one to translate into, so transcription passes none.
        case translates
    }
    public var languageUse: LanguageUse {
        switch self {
        case .qwen3ASR, .whisper, .nemotron, .senseVoice: return .hinted
        case .cohere, .canary: return .required
        case .graniteSpeech: return .translates
        case .parakeet, .voxtralRealtime, .glmASR, .fireRedASR2, .mossTranscribeDiarize, .moonshine, .wav2vec2, .lasrCTC: return .detects
        }
    }
    /// Whether vocabulary hints reach the model as context.
    public var takesVocabulary: Bool { self == .qwen3ASR }
    /// Whether the library has a live session that transcribes while audio arrives.
    public var streamsLive: Bool { self == .nemotron || self == .voxtralRealtime }

    /// An ISO 639-1 code as this family expects it, or nil to let the model decide.
    public func hint(for code: String?) -> String? {
        guard let code = code.map(SpeechScoring.base), !code.isEmpty, code != "und", languageUse == .hinted || languageUse == .required else { return nil }
        switch self {
        case .qwen3ASR:
            if code == "yue" { return "Cantonese" }
            return Locale(identifier: "en_US").localizedString(forLanguageCode: code).map { $0.components(separatedBy: " (").first ?? $0 }
        case .nemotron:
            return ["zh": "zh-CN", "ja": "ja-JP", "th": "th-TH", "vi": "vi-VN", "id": "id-ID", "ms": "ms-MY"][code] ?? code
        default: return code
        }
    }
}

/// A file of a Hugging Face model repository, as the tree listing describes it.
public struct HubFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    /// Git's blob hash, which covers the content of files kept in Git.
    public let gitSHA1: String
    /// Set for files kept in Git LFS, where the Git hash covers only the pointer.
    public let sha256: String?
    public init(path: String, size: Int64, gitSHA1: String, sha256: String?) { self.path = path; self.size = size; self.gitSHA1 = gitSHA1; self.sha256 = sha256 }
}

public enum SpeechModelFiles {
    /// Weights, configs, tokenizers and vocabularies at the top of the repository. Code, pickled
    /// weights and formats MLX cannot read are never fetched, so a model can bring only data.
    public static let readableExtensions: Set<String> = ["json", "safetensors", "txt", "model", "vocab", "mvn", "jinja", "tiktoken"]

    public static func needed(_ files: [HubFile]) -> [HubFile] {
        files.filter { file in
            !file.path.contains("/") && !file.path.hasPrefix(".") && readableExtensions.contains((file.path as NSString).pathExtension.lowercased())
        }
    }

    /// Reads the JSON of `/api/models/{repo}/tree/{revision}`.
    public static func parseTree(_ data: Data) throws -> [HubFile] {
        struct Entry: Decodable { struct LFS: Decodable { let oid: String; let size: Int64 }; let type: String; let path: String; let oid: String; let size: Int64?; let lfs: LFS? }
        return try JSONDecoder().decode([Entry].self, from: data).compactMap { entry in
            guard entry.type == "file" else { return nil }
            return HubFile(path: entry.path, size: entry.lfs?.size ?? entry.size ?? 0, gitSHA1: entry.oid, sha256: entry.lfs?.oid)
        }
    }

    /// "owner/name" with Hugging Face's allowed characters, so a typed name cannot reach another URL.
    public static func isRepository(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.\-]*/[A-Za-z0-9][A-Za-z0-9_.\-]*$"#, options: .regularExpression) != nil && !text.contains("..")
    }
}
