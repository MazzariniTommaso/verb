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
