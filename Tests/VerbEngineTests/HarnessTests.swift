import XCTest
import VerbCore
@testable import VerbEngine

final class HarnessTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Verb-HarnessTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(_ provider: HarnessProvider) throws -> String {
        let source = Bundle.module.url(forResource: "cli", withExtension: "py", subdirectory: "Fixtures")!
        let target = directory.appendingPathComponent(provider.rawValue)
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return target.path
    }
    func testFiveProviderProtocolsCatalogAndCleanup() async throws {
        for provider in HarnessProvider.allCases {
            let executable = try fixture(provider)
            let catalog = try await HarnessClient().discover(provider, override: executable)
            XCTAssertEqual(catalog.models.first?.id, "live-model", provider.rawValue)
            XCTAssertEqual(catalog.models.first?.name, "Live model", provider.rawValue)
            if provider == .codex { XCTAssertEqual(catalog.models.count, 2, "Follow pagination") }
            var settings = Settings(); settings.cleanupProvider = .harness; settings.allowRemoteProcessing = true
            settings.harnessOptions.provider = provider; settings.harnessOptions.model = "live-model"; settings.harnessOptions.executable = executable
            let result = try await ModelClient().edit(text: "Ehm, il gatto è sul divano, anzi sulla sedia.", style: .natural, vocabulary: [VocabularyEntry(word: "Mazzarini")], settings: settings, key: "ignored-api-key")
            XCTAssertEqual(result, "Il gatto è sulla sedia.", provider.rawValue)
        }
    }
    func testRemoteOffRejectsBeforeExecutableOrNetwork() async throws {
        var settings = Settings(); settings.cleanupProvider = .harness
        settings.harnessOptions.model = "live-model"; settings.harnessOptions.executable = "/missing/executable"
        do { _ = try await HarnessClient().edit(system: "", user: "private", settings: settings); XCTFail("Remote must be blocked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Remote processing is off")) }
    }
    func testChildEnvironmentExcludesBillingAndEndpointOverrides() {
        let environment = HarnessClient.environment(executable: "/bin/test")
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL", "CURSOR_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "NODE_OPTIONS", "CLAUDECODE"] { XCTAssertNil(environment[key]) }
        XCTAssertNotNil(environment["HOME"])
    }
    func testTimeoutFailureOutputBoundAndCancellation() async throws {
        let executable = try fixture(.claude)
        for (argument, expected) in [("hang", "took too long"), ("failed", "failed (2)"), ("overflow", "too much output")] {
            let child = try CLIProcess(executable: executable, arguments: [argument], directory: directory, environment: HarnessClient.environment(executable: executable), timeout: argument == "hang" ? 0.15 : 3)
            defer { child.stop() }
            do { _ = try await child.collect(); XCTFail("Expected \(argument)") } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
        let child = try CLIProcess(executable: executable, arguments: ["hang"], directory: directory, environment: HarnessClient.environment(executable: executable), timeout: 10)
        let task = Task { try await withTaskCancellationHandler { try await child.collect() } onCancel: { child.stop() } }
        try await Task.sleep(nanoseconds: 100_000_000); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
    private func spawn(_ executable: String, timeout: TimeInterval = 10) throws -> CLIProcess {
        try CLIProcess(executable: executable, arguments: [], directory: directory, environment: HarnessClient.environment(executable: executable), timeout: timeout)
    }
    func testClaudeArgumentsCarryNoPromptText() throws {
        let system = "Preferred spellings: Mazzarini, Quokkabyte. Text before the cursor: the draft for Giulia."
        let arguments = try HarnessClient.claudeEditArguments(model: "live-model", system: system, in: directory)
        for word in ["Mazzarini", "Quokkabyte", "Giulia", "spellings"] { XCTAssertFalse(arguments.contains { $0.contains(word) }, word) }
        XCTAssertFalse(arguments.contains("--system-prompt"))
        let file = arguments[try XCTUnwrap(arguments.firstIndex(of: "--system-prompt-file")) + 1]
        XCTAssertTrue(file.hasPrefix(directory.path + "/"), "The prompt stays in the call's workspace")
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), system)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testLargeRequestToAChildThatExitsWithoutReading() async throws {
        // Past the 64 KB a pipe holds: the write fails on a closed pipe, and must neither kill the test process nor hang.
        let request = String(repeating: "private words ", count: 100_000)
        for (status, expected) in [(3, "failed (3)"), (0, "closed before completing")] {
            let child = try spawn(try script("refuse-\(status)", "echo 'input refused' >&2\nexit \(status)\n")); defer { child.stop() }
            let start = Date()
            child.sendText(request)
            do { _ = try await child.collect(); XCTFail("A request the CLI never read must not succeed") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected) && error.localizedDescription.contains("input refused"), error.localizedDescription) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }
    func testDeadlineHoldsWhileTheChildReadsNothing() async throws {
        let executable = try script("stall", "exec /bin/sleep 20\n")
        let request = String(repeating: "x", count: 1_100_000)
        for framed in [false, true] {
            let child = try spawn(executable, timeout: 0.3); defer { child.stop() }
            let start = Date()
            do {
                if framed { try child.send(["jsonrpc": "2.0", "id": 1, "method": "edit", "params": ["text": request]]); _ = try await child.next() }
                else { child.sendText(request); _ = try await child.collect() }
                XCTFail("Expected the deadline")
            } catch { XCTAssertTrue(error.localizedDescription.contains("took too long"), error.localizedDescription) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }
    func testInputAndOutputFlowTogether() async throws {
        // cat answers each line while later ones are still being written: in order, nothing lost.
        let echo = try spawn("/bin/cat"); defer { echo.stop() }
        let text = String(repeating: "è", count: 25_000)
        for id in 0..<40 { try echo.send(["id": id, "text": text]) }
        for id in 0..<40 {
            let message = try await echo.next()
            XCTAssertEqual(message["id"] as? Int, id); XCTAssertEqual((message["text"] as? String)?.count, text.count)
        }
        // A child that writes a lot before it reads still gets the whole request.
        let request = String(repeating: "private words ", count: 100_000)
        let chatty = try spawn(try script("chatty", "/usr/bin/yes | /usr/bin/head -c 300000\n/usr/bin/wc -c\n")); defer { chatty.stop() }
        chatty.sendText(request)
        let output = try await chatty.collect()
        XCTAssertTrue(output.hasPrefix("y\ny\n"))
        XCTAssertEqual(output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), String(request.utf8.count))
    }
    func testStopEndsTheWholeProcessTree() async throws {
        // A launcher with one worker that ignores SIGTERM and one that left the process group.
        let child = try spawn(try script("launcher", """
            /bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
            echo "{\\"pid\\": $!}"
            /usr/bin/python3 -c 'import os, time; os.setsid(); print("{\\"pid\\": %d}" % os.getpid(), flush=True); time.sleep(30)' &
            wait
            """))
        var workers: [pid_t] = []
        for _ in 0..<2 { workers.append(pid_t(try await child.next()["pid"] as? Int ?? 0)) }
        XCTAssertTrue(workers.allSatisfy { $0 > 0 && kill($0, 0) == 0 })
        child.stop()
        let deadline = Date().addingTimeInterval(5)
        while workers.contains(where: { kill($0, 0) == 0 }), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(workers.contains { kill($0, 0) == 0 }, "No worker may outlive the child")
        // A child that never started has nothing to stop, and the test's own process group is left alone.
        XCTAssertThrowsError(try spawn(directory.appendingPathComponent("missing").path))
    }
    func testNvmVersionsNewestFirst() throws {
        let home = directory.appendingPathComponent("home").path, node = home + "/.nvm/versions/node/"
        for version in ["v9.11.2", "v20.9.0", "v22.1.0", "v20.11.1"] { try FileManager.default.createDirectory(atPath: node + version + "/bin", withIntermediateDirectories: true) }
        XCTAssertEqual(HarnessClient.nvmBins(home: home), ["v22.1.0", "v20.11.1", "v20.9.0", "v9.11.2"].map { node + $0 + "/bin" })
        // A CLI installed through nvm is found, in the newest Node that has it.
        for version in ["v20.9.0", "v20.11.1"] {
            try "#!/bin/sh\n".write(toFile: node + version + "/bin/gemini", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node + version + "/bin/gemini")
        }
        XCTAssertEqual(HarnessClient.executable(for: .gemini, home: home), node + "v20.11.1/bin/gemini")
    }
    func testMissingCLIMessagesNameEachCLIOnce() async throws {
        for provider in HarnessProvider.allCases {
            do { _ = try await HarnessClient().discover(provider, override: "/missing/" + provider.rawValue); XCTFail("Expected a missing CLI") }
            catch { XCTAssertTrue(error.localizedDescription.contains(" CLI not found.") && !error.localizedDescription.contains("CLI CLI"), error.localizedDescription) }
        }
        var settings = Settings(); settings.cleanupProvider = .harness; settings.allowRemoteProcessing = true
        settings.harnessOptions.provider = .gemini; settings.harnessOptions.model = "live-model"; settings.harnessOptions.executable = "/missing/gemini"
        do { _ = try await HarnessClient().edit(system: "", user: "", settings: settings); XCTFail("Expected a missing CLI") }
        catch { XCTAssertEqual(error.localizedDescription, "Gemini CLI is not installed or its executable moved.") }
    }
    func testCatalogParsersDoNotInventModels() throws {
        try HarnessClient.validateCursorLogin("✓ Logged in as fixture")
        for status in ["Unauthenticated", "Not logged in", "Authenticated using API key", "Unknown account status"] { XCTAssertThrowsError(try HarnessClient.validateCursorLogin(status)) }
        XCTAssertTrue(try HarnessClient.parseCursorModels("Please log in. No models available.").isEmpty)
        XCTAssertEqual(try HarnessClient.parseCursorModels("\u{001B}[32mlive-id - Available name\u{001B}[0m").first?.id, "live-id")
        let grouped: [String: Any] = ["configOptions": [["id": "model", "options": [["name": "Group", "options": [["value": "fresh-id", "name": "Fresh model"]]]]]]]
        XCTAssertEqual(HarnessClient.acpModels(grouped).first?.id, "fresh-id")
        XCTAssertTrue(HarnessClient.parseModels([["id": "--unsafe"], ["id": "hidden-model", "hidden": true]], provider: .codex).isEmpty)
    }
}
