import XCTest
import AVFoundation
import VerbCore
@testable import VerbEngine

final class SpeechTests: XCTestCase {
    func testStereoAudioIsDownmixedAndResampled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 {
            buffer.floatChannelData![0][i] = 0
            buffer.floatChannelData![1][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.5
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let output = try SpeechPCM.read(url)
        XCTAssertEqual(output.count, 16000, accuracy: 2)
        XCTAssertGreaterThan(output.map(abs).max() ?? 0, 0.1, "Right-channel speech must not be discarded")
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }
    func testIncompleteWeightsCannotBeUsedOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LocalSpeech(root: root)
        XCTAssertFalse(engine.installed(SpeechCatalog.defaultID))
        do { try await engine.prepare(SpeechCatalog.defaultID); XCTFail("Missing model must fail before inference or a network fetch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Download the selected MLX")) }
    }
}

/// Long recordings are read a few minutes at a time, with the same audio as a single read.
final class WindowedReadTests: XCTestCase {
    func testWindowsAddUpToTheWholeRecording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/italian.aiff")
        let whole = try SpeechPCM.read(url)
        let reader = try SpeechPCMReader(url)
        var parts: [Float] = []
        repeat { parts += try reader.read(seconds: 1) } while !reader.atEnd
        XCTAssertEqual(Double(parts.count), Double(whole.count), accuracy: 64)
        XCTAssertEqual(reader.duration, Double(whole.count) / 16000, accuracy: 0.05)
    }
}

/// Installing models from Hugging Face: what counts as a complete, untampered folder.
final class SpeechModelInstallTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("verb-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testFilesAreCheckedAgainstTheHashTheRepositoryPublishes() throws {
        let file = folder.appendingPathComponent("vocab.txt")
        try Data("hello".utf8).write(to: file)
        // `git hash-object` and `shasum -a 256` of "hello".
        XCTAssertTrue(try SpeechModelInstaller.matches(file, HubFile(path: "vocab.txt", size: 5, gitSHA1: "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", sha256: nil)))
        XCTAssertTrue(try SpeechModelInstaller.matches(file, HubFile(path: "vocab.txt", size: 5, gitSHA1: "pointer", sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")))
        XCTAssertFalse(try SpeechModelInstaller.matches(file, HubFile(path: "vocab.txt", size: 5, gitSHA1: "0000000000000000000000000000000000000000", sha256: nil)))
        XCTAssertFalse(try SpeechModelInstaller.matches(file, HubFile(path: "vocab.txt", size: 6, gitSHA1: "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", sha256: nil)), "A wrong size fails before any hashing")
    }
    func testAFolderIsCompleteOnlyWithItsRecordAndEveryFile() throws {
        try Data(#"{"model_type": "cohere_asr"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertEqual(try SpeechModels.architecture(of: folder), .cohere)
        XCTAssertNil(SpeechModelInstaller.record(in: folder), "No record yet: the download may have stopped halfway")
        let record = SpeechModelInstaller.Record(repository: "owner/model", revision: "abc", architecture: .cohere, files: [HubFile(path: "config.json", size: 28, gitSHA1: "x", sha256: nil), HubFile(path: "model.safetensors", size: 4, gitSHA1: "y", sha256: "z")], companion: nil)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent(SpeechModelInstaller.recordName))
        XCTAssertNil(SpeechModelInstaller.record(in: folder), "The weights are missing")
        try Data("abcd".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(SpeechModelInstaller.record(in: folder), record)
    }
    func testWhisperTokenizersComeFromTheMatchingOriginal() {
        XCTAssertEqual(SpeechModelInstaller.whisperTokenizerRepository(config: Data(#"{"n_vocab": 51866}"#.utf8)), "openai/whisper-large-v3")
        XCTAssertEqual(SpeechModelInstaller.whisperTokenizerRepository(config: Data(#"{"vocab_size": 51865}"#.utf8)), "openai/whisper-medium")
        XCTAssertEqual(SpeechModelInstaller.whisperTokenizerRepository(config: Data(#"{"n_vocab": 51864}"#.utf8)), "openai/whisper-medium.en")
    }
}
