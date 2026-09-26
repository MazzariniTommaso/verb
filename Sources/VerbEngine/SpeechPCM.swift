import Foundation
import AVFoundation
import VerbCore

public enum SpeechPCM {
    /// The longest recording Verb writes down, in seconds.
    public static let longest: Double = 4 * 3600
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        guard file.length > 0 else { throw VerbError("This recording contains no audio.") }
        guard Double(file.length) / source.sampleRate <= SpeechPCM.longest else { throw VerbError("Use a recording up to 4 hours long.") }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { throw VerbError("Could not read the recording.") }
        try file.read(into: input)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: source, to: target), let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / source.sampleRate)) + 4096) else { throw VerbError("Could not prepare 16 kHz audio for MLX.") }
        converter.downmix = true
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw error ?? VerbError("Could not convert the recording.") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw VerbError("The recording contains invalid audio samples.") }
        return samples
    }
}

/// Reads a recording a few minutes at a time as 16 kHz mono, so an hour-long dictation never
/// sits in memory whole.
public final class SpeechPCMReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    public private(set) var atEnd = false
    public let duration: Double

    public init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        duration = Double(file.length) / source.sampleRate
        guard file.length > 0 else { throw VerbError("This recording contains no audio.") }
        guard duration <= SpeechPCM.longest else { throw VerbError("Use a recording up to 4 hours long.") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: source, to: target) else { throw VerbError("Could not prepare 16 kHz audio for MLX.") }
        converter.downmix = true
        self.target = target; self.converter = converter
    }

    /// The next `seconds` of audio, or fewer at the end; empty once the recording is read.
    public func read(seconds: Double) throws -> [Float] {
        guard !atEnd else { return [] }
        let source = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length - file.framePosition), seconds * source.sampleRate))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { atEnd = true; return [] }
        try file.read(into: input, frameCount: frames)
        if file.framePosition >= file.length { atEnd = true }
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / source.sampleRate)) + 4096) else { throw VerbError("Could not convert the recording.") }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = self.atEnd ? .endOfStream : .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw error ?? VerbError("Could not convert the recording.") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw VerbError("The recording contains invalid audio samples.") }
        return samples
    }
}
