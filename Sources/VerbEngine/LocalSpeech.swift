import Foundation
import CryptoKit
import NaturalLanguage
import MLX
import MLXAudioCore
import MLXAudioSTT
import VerbCore

public struct SpeechResult: Sendable {
    public let text: String
    public let language: String
    public let seconds: Double
    public init(text: String, language: String, seconds: Double) { self.text = text; self.language = language; self.seconds = seconds }
}

/// Downloads one file with progress. After a dropped connection it carries on from where it
/// stopped, a few times, instead of starting over; the caller still checks size and SHA-256.
/// A session delegate, because the async download API reports no progress to a task delegate.
final class SpeechDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Failures that may not happen again a moment later.
    private static let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var waiting: CheckedContinuation<(URL, URLResponse), Error>?, kept: URL?
    private init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    static func fetch(_ url: URL, configuration: URLSessionConfiguration, attempts: Int = 4, progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let download = SpeechDownload(report: progress)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var resumeData: Data?, attempt = 1
        while true {
            do {
                let (file, response) = try await download.run(resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url))
                guard let http = response as? HTTPURLResponse else { try? FileManager.default.removeItem(at: file); throw URLError(.badServerResponse) }
                // An offer to resume can lapse, such as a signed CDN link that expired: start over.
                if resumeData != nil, !(200..<300).contains(http.statusCode), attempt < attempts { try? FileManager.default.removeItem(at: file); resumeData = nil; attempt += 1; continue }
                return (file, http)
            } catch let error as URLError where attempt < attempts && !Task.isCancelled && transient.contains(error.code) {
                resumeData = error.downloadTaskResumeData
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000); attempt += 1
            }
        }
    }
    private func run(_ task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                lock.lock(); waiting = continuation; kept = nil; lock.unlock()
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes the file once this returns.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Verb-download-" + UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: file)) != nil
        lock.lock(); kept = moved ? file : nil; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = waiting, file = kept; waiting = nil; kept = nil; lock.unlock()
        if let error { if let file { try? FileManager.default.removeItem(at: file) }; continuation?.resume(throwing: error) }
        else if let file, let response = task.response { continuation?.resume(returning: (file, response)) }
        else { continuation?.resume(throwing: URLError(.cannotWriteToFile)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) { report(fileOffset) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
}

public actor LocalSpeech {
    private enum Pipeline { case parakeet(ParakeetModel), qwen(Qwen3ASRModel) }
    private var pipeline: Pipeline?
    private var loadedID: String?
    private var preparing = false
    private var transcribing = false
    public let root: URL
    private let bundledRoot: URL?
    public init(root: URL, bundledRoot: URL? = nil) { self.root = root; self.bundledRoot = bundledRoot }

    public nonisolated func modelFolder(_ variant: String) -> URL {
        if let bundledRoot {
            let folder = bundledRoot.appendingPathComponent(variant)
            if complete(folder, variant: variant) { return folder }
        }
        return root.appendingPathComponent("MLX", isDirectory: true).appendingPathComponent(variant, isDirectory: true)
    }
    /// Written after a download is verified, with the revision it holds.
    private static let readyMarker = ".verb-ready"
    private nonisolated func complete(_ folder: URL, variant: String) -> Bool {
        let marker = try? String(contentsOf: folder.appendingPathComponent(Self.readyMarker), encoding: .utf8)
        guard let model = try? SpeechCatalog.model(variant), let marker, marker.trimmingCharacters(in: .whitespacesAndNewlines) == model.revision else { return false }
        return model.files.allSatisfy { file in
            let size = try? folder.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return Int64(size ?? -1) == file.bytes
        } && (variant != "qwen3-asr-0.6b-4bit" || FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path))
    }
    public nonisolated func installed(_ variant: String) -> Bool { complete(modelFolder(variant), variant: variant) }

    private func verify(_ url: URL, file: SpeechModelFile) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes else { return false }
        guard let expected = file.sha256 else { return true }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
    public func install(_ variant: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let model = try SpeechCatalog.model(variant)
        if installed(variant) { try await prepare(variant); progress(1, "MLX model ready offline"); return }
        let folder = root.appendingPathComponent("MLX").appendingPathComponent(variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = URLSessionConfiguration.ephemeral
        // Hours: the 2.5 GB Parakeet weights take that long on a slow connection.
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 24 * 3600
        config.urlCache = nil; config.httpCookieStorage = nil
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(file.name)
            progress(Double(completed) / Double(model.downloadBytes) * 0.92, "Checking \(file.name)…")
            if try verify(destination, file: file) { completed += file.bytes; continue }
            let startBytes = completed
            let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.name)")!
            let (temporary, response) = try await SpeechDownload.fetch(url, configuration: config) { received in
                progress(min(0.92, Double(startBytes + received) / Double(model.downloadBytes) * 0.92), "Downloading \(model.name)…")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            // A resumed download answers 206 with the rest; the checksum covers the whole file.
            guard [200, 206].contains(response.statusCode), try verify(temporary, file: file) else { throw VerbError("Speech model download failed its integrity check. Retry the download.") }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            completed += file.bytes
        }
        progress(0.94, "Preparing MLX on the Apple GPU…")
        try await load(variant, folder: folder)
        try Task.checkCancellation()
        try (model.revision + "\n").write(to: folder.appendingPathComponent(Self.readyMarker), atomically: true, encoding: .utf8)
        progress(1, "MLX model ready offline")
    }
    private func load(_ variant: String, folder: URL) async throws {
        while preparing || transcribing { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 30_000_000) }
        if loadedID == variant, pipeline != nil { return }
        preparing = true; defer { preparing = false }
        pipeline = nil; loadedID = nil
        Memory.cacheLimit = 256 * 1024 * 1024
        Memory.clearCache()
        try Task.checkCancellation()
        switch variant {
        case "parakeet-v3": pipeline = .parakeet(try ParakeetModel.fromDirectory(folder))
        case "qwen3-asr-0.6b-4bit": pipeline = .qwen(try await Qwen3ASRModel.fromModelDirectory(folder))
        default: throw VerbError("Choose an MLX speech model in Models.")
        }
        try Task.checkCancellation(); loadedID = variant
    }
    public func prepare(_ variant: String) async throws {
        guard installed(variant) else { throw VerbError("Download the selected MLX speech model in Models to enable offline dictation.") }
        try await load(variant, folder: modelFolder(variant))
    }
    public func unload() { guard !preparing, !transcribing else { return }; pipeline = nil; loadedID = nil; Memory.clearCache() }

    public func transcribe(url: URL, variant: String, language: DictationLanguage, vocabulary: [VocabularyEntry]) async throws -> SpeechResult {
        let pipeline = try await claim(variant); defer { transcribing = false; Memory.clearCache() }
        let started = Date()
        // Five minutes at a time, cut near quiet points; the part after the last cut waits for the next five.
        let reader = try SpeechPCMReader(url)
        var texts: [String] = [], detected: String?, carry: [Float] = [], heardAny = false
        repeat {
            try Task.checkCancellation()
            let window = try reader.read(seconds: 300)
            heardAny = heardAny || !window.isEmpty
            let buffer = carry + window
            guard !buffer.isEmpty else { break }
            let ranges = SpeechChunking.ranges(samples: buffer, sampleRate: 16000)
            let ready = reader.atEnd ? ranges[...] : ranges.dropLast()
            for range in ready {
                let result = try await decode(Array(buffer[range]), with: pipeline, language: language, vocabulary: vocabulary)
                texts.append(TextRules.tidy(result.text)); detected = result.language ?? detected
            }
            carry = reader.atEnd ? [] : Array(buffer[(ranges.last?.lowerBound ?? 0)...])
        } while !reader.atEnd || !carry.isEmpty
        guard heardAny else { throw VerbError("This recording contains no audio.") }
        let text = TextRules.tidy(texts.joined(separator: " "))
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let code: String
        if language != .auto { code = language.rawValue }
        else if let detected, detected.lowercased().contains("italian") { code = "it" }
        else if let detected, detected.lowercased().contains("english") { code = "en" }
        else { code = recognizer.dominantLanguage?.rawValue ?? "auto" }
        return SpeechResult(text: text, language: code, seconds: Date().timeIntervalSince(started))
    }

    /// Recognizes a few seconds already in memory, such as a possible "Ehi Verb". Nothing
    /// is written to disk.
    public func recognize(samples: [Float], variant: String, language: DictationLanguage) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let pipeline = try await claim(variant); defer { transcribing = false }
        return TextRules.tidy(try await decode(samples, with: pipeline, language: language, vocabulary: []).text)
    }

    /// Waits until the engine is free, then takes it. Short voice checks and full dictations
    /// share one model and run one at a time.
    private func claim(_ variant: String) async throws -> Pipeline {
        while true {
            try await prepare(variant)
            while transcribing || preparing { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
            if let pipeline, loadedID == variant { transcribing = true; return pipeline }
        }
    }

    private func decode(_ samples: [Float], with pipeline: Pipeline, language: DictationLanguage, vocabulary: [VocabularyEntry]) async throws -> STTOutput {
        try Task.checkCancellation()
        let audio = MLXArray(samples)
        switch pipeline {
        case .parakeet(let model):
            let result = model.generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 512, language: nil, chunkDuration: 30))
            try Task.checkCancellation()
            return result
        case .qwen(let model):
            var final: STTOutput?
            let stream = model.generateStream(audio: audio, maxTokens: 512, temperature: 0, context: vocabulary.prefix(100).map(\.word).joined(separator: ", "), language: language == .auto ? nil : language == .it ? "Italian" : "English", chunkDuration: 30)
            for try await event in stream {
                try Task.checkCancellation()
                if case .result(let output) = event { final = output }
            }
            try Task.checkCancellation()
            guard let final, final.generationTokens < 512 else { throw VerbError("The MLX speech model returned incomplete text. Retry with another model.") }
            return final
        }
    }
}
