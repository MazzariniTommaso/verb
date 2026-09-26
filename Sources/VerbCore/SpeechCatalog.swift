import Foundation

public struct SpeechModelFile: Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String?
}
public struct LocalSpeechModel: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let repository: String
    public let revision: String
    public let files: [SpeechModelFile]
    public var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}
public enum SpeechCatalog {
    public static let defaultID = "parakeet-v3"
    public static func model(_ id: String) throws -> LocalSpeechModel {
        guard let model = models.first(where: { $0.id == id }) else { throw VerbError("Choose an MLX speech model in Models.") }
        return model
    }
    public static let models: [LocalSpeechModel] = [
        LocalSpeechModel(id: "parakeet-v3", name: "Parakeet v3 · MLX", detail: "Fast multilingual dictation · Italian and English · 2.51 GB", repository: "mlx-community/parakeet-tdt-0.6b-v3", revision: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", files: [
            SpeechModelFile(name: "config.json", bytes: 244093, sha256: nil),
            SpeechModelFile(name: "model.safetensors", bytes: 2508288736, sha256: "05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592"),
            SpeechModelFile(name: "tokenizer.model", bytes: 360916, sha256: "eacec2b0a77f336d4a2ca4a25a7047575d3c2b74de47e997f4c205126ed3135e"),
            SpeechModelFile(name: "tokenizer.vocab", bytes: 101024, sha256: nil),
            SpeechModelFile(name: "vocab.txt", bytes: 46772, sha256: nil)
        ]),
        LocalSpeechModel(id: "qwen3-asr-0.6b-4bit", name: "Qwen3 ASR 0.6B · MLX 4-bit", detail: "Compact multilingual model · language and vocabulary hints · 713 MB", repository: "mlx-community/Qwen3-ASR-0.6B-4bit", revision: "313d850181767edf09f00a9c289becca70e58cd0", files: [
            SpeechModelFile(name: "chat_template.json", bytes: 1161, sha256: nil),
            SpeechModelFile(name: "config.json", bytes: 7187, sha256: nil),
            SpeechModelFile(name: "generation_config.json", bytes: 142, sha256: nil),
            SpeechModelFile(name: "merges.txt", bytes: 1671853, sha256: nil),
            SpeechModelFile(name: "model.safetensors", bytes: 708236945, sha256: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"),
            SpeechModelFile(name: "model.safetensors.index.json", bytes: 71814, sha256: nil),
            SpeechModelFile(name: "preprocessor_config.json", bytes: 330, sha256: nil),
            SpeechModelFile(name: "tokenizer_config.json", bytes: 12487, sha256: nil),
            SpeechModelFile(name: "vocab.json", bytes: 2776833, sha256: nil)
        ])
    ]
}
