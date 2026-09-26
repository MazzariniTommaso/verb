import AVFoundation
import XCTest
@testable import VerbCore

/// A recording cut short by a crash still plays and retries.
final class RecordingTests: XCTestCase {
    func testACutRecordingGetsItsSizesBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verb-cut-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
            buffer.frameLength = 32000
            for i in 0..<32000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
            try file.write(from: buffer)
        }
        // As a crash leaves it: the sizes in the header never written.
        let handle = try FileHandle(forUpdating: url)
        let header = try handle.read(upToCount: 4096)!
        let data = header.range(of: Data("data".utf8))!.lowerBound
        var zero = UInt32(0)
        try handle.seek(toOffset: 4); try handle.write(contentsOf: Data(bytes: &zero, count: 4))
        try handle.seek(toOffset: UInt64(data + 4)); try handle.write(contentsOf: Data(bytes: &zero, count: 4))
        try handle.close()
        XCTAssertNotEqual((try? AVAudioFile(forReading: url))?.length ?? 0, 32000)
        WAVRepair.repair(url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000)
        WAVRepair.repair(url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000, "a sound file is left as it is")
    }
}
