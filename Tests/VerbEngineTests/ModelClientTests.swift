import XCTest
import CryptoKit
import VerbCore
@testable import VerbEngine

/// Runs against a local OpenAI-compatible server, Fixtures/endpoint.py, which logs each request.
final class EndpointTests: XCTestCase {
    private var server: Process!, log: URL!, base = "", checksum = ""
    override func setUpWithError() throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("Verb-EndpointTests-" + UUID().uuidString + ".log")
        let output = Pipe()
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.standardOutput = output
        server.arguments = [Bundle.module.url(forResource: "endpoint", withExtension: "py", subdirectory: "Fixtures")!.path, log.path]
        try server.run()
        // Once it listens, the server prints its port and the download's checksum.
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let fields = try XCTUnwrap(line.count == 2 ? line : nil, "The fixture server did not start")
        base = "http://127.0.0.1:" + fields[0]; checksum = fields[1]
    }
    override func tearDownWithError() throws { server.terminate(); server.waitUntilExit(); try? FileManager.default.removeItem(at: log) }
    private func requests() throws -> [[String: Any]] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    private func edit(_ path: String, model: String, remote: Bool = false) async throws -> String {
        var settings = Settings(); settings.cleanupProvider = .endpoint; settings.cleanupEndpoint = base + path
        settings.hostedCleanupModel = model; settings.allowRemoteProcessing = remote
        return try await ModelClient().edit(text: "Ciao test.", style: .natural, vocabulary: [], settings: settings, key: "")
    }
    func testReasoningModelRetriesWithoutSamplingParameters() async throws {
        let result = try await edit("/reasoning/v1/chat/completions", model: "gpt-5-mini")
        XCTAssertEqual(result, "Ciao test.")
        let sent = try requests().compactMap { $0["keys"] as? [String] }
        XCTAssertEqual(sent.count, 2, "One retry")
        XCTAssertTrue(sent[0].contains("temperature") && sent[0].contains("max_tokens"))
        XCTAssertFalse(sent[1].contains("temperature") || sent[1].contains("max_tokens"))
        XCTAssertTrue(sent[1].contains("max_completion_tokens"))
    }
    func testOtherBadRequestsAreNotRetried() async throws {
        do { _ = try await edit("/invalid/v1/chat/completions", model: "gpt-4o-mini"); XCTFail("A bad request must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "The model server returned HTTP 400.") }
        XCTAssertEqual(try requests().count, 1)
    }
    func testLoopbackCloudModelNeedsRemoteProcessing() async throws {
        // An Ollama on this Mac runs “-cloud” models remotely.
        do { _ = try await edit("/v1/chat/completions", model: "gpt-oss:120b-cloud"); XCTFail("Remote processing is off") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Cloud models are not allowed"), error.localizedDescription) }
        XCTAssertTrue(try requests().isEmpty, "Nothing may reach the server")
        let result = try await edit("/v1/chat/completions", model: "gpt-oss:120b-cloud", remote: true)
        XCTAssertEqual(result, "Ciao test.")
    }
    func testDroppedDownloadResumes() async throws {
        let largest = Largest()
        let (file, response) = try await SpeechDownload.fetch(URL(string: base + "/weights.bin")!, configuration: .ephemeral) { largest.note($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined(), checksum)
        let ranges = try requests().compactMap { $0["range"] as? String }
        XCTAssertEqual(ranges.count, 1, "The second request carries on from the dropped one")
        XCTAssertFalse(ranges.first?.hasPrefix("bytes=0-") ?? true)
        XCTAssertEqual(largest.value, 3_000_000, "Progress reaches the whole file")
    }
}

private final class Largest: @unchecked Sendable {
    private let lock = NSLock()
    private var largest: Int64 = 0
    func note(_ value: Int64) { lock.lock(); largest = max(largest, value); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return largest }
}

final class UploadTests: XCTestCase {
    func testUploadsConvertWhatProvidersRefuseAndDropStaleCopies() async throws {
        for (name, size, convert) in [("import.aiff", 3_000_000, true), ("note.caf", 1_000, true), ("dictation.wav", 11_000_000, true), ("dictation.WAV", 3_000_000, false), ("memo.m4a", 9_000_000, false), ("call.webm", 5_000_000, false)] {
            XCTAssertEqual(ModelClient.needsConversion(URL(fileURLWithPath: "/tmp/" + name), size: size), convert, name)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Verb-UploadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appendingPathComponent("Verb-upload-stale.m4a"), fresh = folder.appendingPathComponent("Verb-upload-fresh.m4a"), unrelated = folder.appendingPathComponent("notes.m4a")
        for file in [stale, fresh, unrelated] { try Data([1]).write(to: file) }
        for file in [stale, unrelated] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path) }
        let aiff = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/english.aiff")
        let upload = try await ModelClient().compactUpload(aiff, in: folder)
        XCTAssertEqual(upload.pathExtension, "m4a")
        XCTAssertEqual(upload.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent)
        let attributes = try FileManager.default.attributesOfItem(atPath: upload.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 1000)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "A copy an earlier upload left behind goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "An upload under way keeps its copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testQuickCallsFailFastWhileModelsGetTime() {
        XCTAssertEqual(ModelClient.quick.configuration.timeoutIntervalForResource, 240)
        XCTAssertGreaterThanOrEqual(ModelClient.work.configuration.timeoutIntervalForRequest, 300)
        XCTAssertGreaterThanOrEqual(ModelClient.download.configuration.timeoutIntervalForResource, 6 * 3600)
    }
}
