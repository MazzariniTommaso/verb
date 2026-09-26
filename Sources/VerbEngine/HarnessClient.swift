import Foundation
import VerbCore

public final class HarnessClient: @unchecked Sendable {
    /// The app's version, for the CLIs that ask who is connecting.
    static var clientVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    public init() {}
    /// Subscription logins confirmed in the last ten minutes, by executable. Checking before
    /// every dictation costs seconds; a login rarely changes between two of them.
    private static let confirmed = NSLock()
    nonisolated(unsafe) private static var confirmedAt: [String: Date] = [:]
    private static func recentlyConfirmed(_ key: String) -> Bool {
        confirmed.lock(); defer { confirmed.unlock() }
        return confirmedAt[key].map { Date().timeIntervalSince($0) < 600 } ?? false
    }
    private static func confirm(_ key: String) { confirmed.lock(); confirmedAt[key] = Date(); confirmed.unlock() }
    public static func executable(for provider: HarnessProvider, override: String = "", home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        let fm = FileManager.default
        if !override.isEmpty { return override.hasPrefix("/") && fm.isExecutableFile(atPath: override) ? override : nil }
        let directories = [home + "/.local/bin", home + "/.cursor/bin", home + "/.bun/bin", home + "/.volta/bin"] + nvmBins(home: home) + ["/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for name in provider.commands { for directory in directories where directory.hasPrefix("/") { let candidate = directory + "/" + name; if fm.isExecutableFile(atPath: candidate) { return candidate } } }
        if provider == .codex { for app in ["ChatGPT", "Codex"] { let path = "/Applications/\(app).app/Contents/Resources/codex"; if fm.isExecutableFile(atPath: path) { return path } } }
        return nil
    }
    /// The bin folders of the Node versions nvm installed, newest first, compared as numbers:
    /// v22.1.0, v20.11.1, v20.9.0, v9.11.2.
    static func nvmBins(home: String) -> [String] {
        let root = home + "/.nvm/versions/node"
        func version(_ name: String) -> [Int] { name.drop(while: { !$0.isNumber }).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }
        return names.sorted { version($1).lexicographicallyPrecedes(version($0)) }.map { root + "/" + $0 + "/bin" }
    }
    /// The CLI's name in messages: “Codex CLI”, and “Gemini CLI” rather than “Gemini CLI CLI”.
    private static func cliName(_ provider: HarnessProvider) -> String { provider.title.hasSuffix("CLI") ? provider.title : provider.title + " CLI" }
    static func environment(executable: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"].contains($0.key) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, home + "/.local/bin", home + "/.volta/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + nvmBins(home: home)
        result["PATH"] = path.joined(separator: ":"); result["NO_COLOR"] = "1"; result["TERM"] = "dumb"
        result["DISABLE_AUTOUPDATER"] = "1"; result["DISABLE_TELEMETRY"] = "1"; result["DISABLE_ERROR_REPORTING"] = "1"
        return result // API keys, alternate endpoints, nested-agent variables and token overrides are not inherited.
    }
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Verb-CLI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
    }
    private func run(_ executable: String, _ arguments: [String], in directory: URL, input: String = "", timeout: TimeInterval = 35, environment: [String: String]? = nil) async throws -> String {
        let child = try CLIProcess(executable: executable, arguments: arguments, directory: directory, environment: environment ?? Self.environment(executable: executable), timeout: timeout)
        defer { child.stop() }
        return try await withTaskCancellationHandler { child.sendText(input); return try await child.collect() } onCancel: { child.stop() }
    }
    private func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VerbError("The CLI returned an unsupported response. Update it and refresh the connection.") }
        return object
    }
    private static let claudeArguments = ["-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--permission-mode", "dontAsk", "--disable-slash-commands"]
    /// The system prompt carries dictionary words and text read around the cursor. argv shows up
    /// in process listings and security logs, so the prompt goes in a private file of the call's
    /// workspace instead.
    static func claudeEditArguments(model: String, system: String, in directory: URL) throws -> [String] {
        let prompt = directory.appendingPathComponent("system-prompt.txt")
        let descriptor = open(prompt.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(system.utf8)); try handle.close()
        return claudeArguments + ["--model", model, "--output-format", "json", "--system-prompt-file", prompt.path]
    }
    private func claudeAccount(_ executable: String, _ directory: URL) async throws -> String {
        try HarnessPolicy.subscriptionAccount(.claude, object(await run(executable, ["--safe-mode", "auth", "status", "--json"], in: directory)))
    }
    private func codex(_ executable: String, _ directory: URL) throws -> CLIProcess {
        try CLIProcess(executable: executable, arguments: ["app-server", "-c", "model_provider=\"openai\"", "-c", "forced_login_method=\"chatgpt\"", "-c", "analytics.enabled=false", "-c", "features.hooks=false"], directory: directory, environment: Self.environment(executable: executable), timeout: 40)
    }
    private func initializeCodex(_ child: CLIProcess) async throws -> String {
        _ = try await child.request("initialize", ["clientInfo": ["name": "verb", "title": "Verb", "version": Self.clientVersion]], id: 1)
        try child.send(["method": "initialized", "params": [:]])
        let result = try await child.request("account/read", ["refreshToken": false], id: 2)
        return try HarnessPolicy.subscriptionAccount(.codex, result["account"] as? [String: Any] ?? [:])
    }
    public func discover(_ provider: HarnessProvider, override: String = "") async throws -> HarnessCatalog {
        guard let executable = Self.executable(for: provider, override: override) else { throw VerbError("\(Self.cliName(provider)) not found. Install it or choose its executable, sign in, then refresh.") }
        let directory = try workspace(); defer { try? FileManager.default.removeItem(at: directory) }
        var models: [HarnessModel] = [], account = "", source = ""
        switch provider {
        case .claude:
            account = try await claudeAccount(executable, directory)
            let child = try CLIProcess(executable: executable, arguments: Self.claudeArguments + ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"], directory: directory, environment: Self.environment(executable: executable), timeout: 35)
            defer { child.stop() }
            models = try await withTaskCancellationHandler {
                try child.send(["type": "control_request", "request_id": "catalog", "request": ["subtype": "initialize"]])
                while true {
                    let event = try await child.next()
                    guard let response = event["response"] as? [String: Any], response["request_id"] as? String == "catalog" else { continue }
                    guard response["subtype"] as? String == "success", let result = response["response"] as? [String: Any] else { throw VerbError("Claude could not return its model list.") }
                    return Self.parseModels(result["models"], provider: .claude)
                }
            } onCancel: { child.stop() }
            source = "Claude Code initialization · current CLI/account catalog"
        case .codex:
            let child = try codex(executable, directory); defer { child.stop() }
            (account, models) = try await withTaskCancellationHandler {
                let account = try await initializeCodex(child)
                var result: [HarnessModel] = [], cursor: String?, id = 10
                repeat {
                    var parameters: [String: Any] = ["limit": 100, "includeHidden": false]
                    if let cursor { parameters["cursor"] = cursor }
                    let page = try await child.request("model/list", parameters, id: id); id += 1
                    result += Self.parseModels(page["data"], provider: .codex); cursor = page["nextCursor"] as? String
                    guard id < 30 else { throw VerbError("The CLI returned too many catalog pages.") }
                } while cursor != nil
                return (account, result)
            } onCancel: { child.stop() }
            source = "Codex model/list · signed-in account"
        case .cursor:
            let status = try await run(executable, ["status"], in: directory)
            try Self.validateCursorLogin(status)
            account = "Cursor CLI login"; source = "Cursor --list-models · current CLI/account catalog"
            models = try Self.parseCursorModels(await run(executable, ["--list-models"], in: directory))
        case .gemini:
            let child = try acpProcess(executable, directory, provider: provider); defer { child.stop() }
            models = try await withTaskCancellationHandler {
                let session = try await initializeACP(child, directory: directory, provider: .gemini)
                return Self.acpModels(session)
            } onCancel: { child.stop() }
            account = "Gemini CLI · Google login"; source = "Gemini ACP session · available models"
        case .copilot:
            let child = try copilot(executable, directory); defer { child.stop() }
            (account, models) = try await withTaskCancellationHandler {
                let status = try await copilotAccount(child)
                let account = try HarnessPolicy.subscriptionAccount(.copilot, status)
                let result = try await child.request("models.list", [:], id: 2)
                return (account, Self.parseModels(result["models"], provider: .copilot))
            } onCancel: { child.stop() }
            source = "Copilot models.list · signed-in account"
        }
        var seen = Set<String>(); models = models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard !models.isEmpty else { throw VerbError("\(provider.title) returned no supported models. Update the CLI or check model access in your account. No static list has been substituted.") }
        return HarnessCatalog(provider: provider, executable: executable, models: models, account: account, source: source)
    }
    static func parseModels(_ value: Any?, provider: HarnessProvider) -> [HarnessModel] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard item["hidden"] as? Bool != true, let id = (item["value"] ?? item["model"] ?? item["id"] ?? item["modelId"]) as? String, (try? HarnessPolicy.validateModel(id)) != nil else { return nil }
            let resolved = item["resolvedModel"] as? String
            let detail = item["description"] as? String ?? ""
            var name = (item["displayName"] ?? item["name"]) as? String ?? id
            // Claude's human description exposes the concrete version behind aliases such as haiku.
            if provider == .claude, let first = detail.components(separatedBy: " · ").first, !first.isEmpty { name = first }
            return HarnessModel(id: id, name: id == "default" ? name + " (default)" : name, detail: detail, resolvedID: resolved)
        }
    }
    static func validateCursorLogin(_ value: String) throws {
        let status = value.lowercased()
        guard !["not logged in", "not authenticated", "unauthenticated", "logged out", "api key", "apikey", "api_key"].contains(where: status.contains), status.range(of: "\\b(logged in|authenticated)\\b", options: .regularExpression) != nil else { throw VerbError("Use agent login to connect your Cursor subscription, then refresh. Verb could not verify a subscription login.") }
    }
    static func parseCursorModels(_ value: String) throws -> [HarnessModel] {
        let clean = value.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        if let data = clean.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            let dictionary = json as? [String: Any]
            let models = parseModels(dictionary?["models"] ?? dictionary?["data"] ?? json, provider: .cursor)
            if !models.isEmpty { return models }
        }
        return clean.components(separatedBy: .newlines).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = text.range(of: "^[a-z0-9][a-z0-9._:/-]*(?=\\s+[-–—]\\s+)", options: .regularExpression) else { return nil }
            let id = String(text[match]), label = text[match.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
            return HarnessModel(id: id, name: label.isEmpty ? id : label)
        }
    }
    static func acpModels(_ session: [String: Any]) -> [HarnessModel] {
        let models = session["models"] as? [String: Any] ?? [:]
        let listed = parseModels(models["availableModels"], provider: .gemini)
        if !listed.isEmpty { return listed }
        let options = session["configOptions"] as? [[String: Any]] ?? []
        return options.filter { $0["category"] as? String == "model" || $0["id"] as? String == "model" }.flatMap { option -> [HarnessModel] in
            func flatten(_ entries: [[String: Any]]) -> [HarnessModel] { entries.flatMap { entry in if let group = entry["options"] as? [[String: Any]] { return flatten(group) }; return parseModels([entry], provider: .gemini) } }
            return flatten(option["options"] as? [[String: Any]] ?? [])
        }
    }
    private func acpProcess(_ executable: String, _ directory: URL, provider: HarnessProvider) throws -> CLIProcess {
        var environment = Self.environment(executable: executable)
        // Highest-precedence system settings apply only to this child; the user's settings are untouched.
        let configuration: [String: Any] = ["security": ["auth": ["selectedType": "oauth-personal", "enforcedType": "oauth-personal"]], "hooksConfig": ["enabled": false], "telemetry": ["enabled": false], "privacy": ["usageStatisticsEnabled": false], "context": ["fileName": "VERB_NO_CONTEXT.md", "includeDirectories": []], "mcp": ["allowed": []], "tools": ["core": []], "general": ["enableAutoUpdate": false]]
        let config = directory.appendingPathComponent("gemini-system.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: config)
        environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = config.path
        let policy = directory.appendingPathComponent("verb-deny-tools.toml")
        try "[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n".write(to: policy, atomically: true, encoding: .utf8)
        return try CLIProcess(executable: executable, arguments: ["--experimental-acp", "--extensions", "none", "--allowed-mcp-server-names", "verb-no-mcp", "--policy", policy.path], directory: directory, environment: environment, timeout: 100)
    }
    private func initializeACP(_ child: CLIProcess, directory: URL, provider: HarnessProvider) async throws -> [String: Any] {
        _ = try await child.request("initialize", ["protocolVersion": 1, "clientInfo": ["name": "verb", "version": Self.clientVersion], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], id: 1)
        return try await child.request("session/new", ["cwd": directory.path, "mcpServers": []], id: 2)
    }
    private func copilotAccount(_ child: CLIProcess) async throws -> [String: Any] {
        _ = try await child.request("connect", ["clientInfo": ["editorName": "Verb", "editorVersion": Self.clientVersion], "supportedTaskKinds": []], id: 0)
        return try await child.request("auth.getStatus", [:], id: 1)
    }
    private func copilot(_ executable: String, _ directory: URL) throws -> CLIProcess {
        try CLIProcess(executable: executable, arguments: ["--headless", "--stdio", "--no-auto-update", "--log-level", "error"], directory: directory, environment: Self.environment(executable: executable), timeout: 100, framing: .contentLength)
    }
    public func edit(system: String, user: String, settings: Settings) async throws -> String {
        try HarnessPolicy.requireCloud(settings)
        let options = settings.harnessOptions, provider = options.provider
        guard let executable = Self.executable(for: provider, override: options.executable) else { throw VerbError("\(Self.cliName(provider)) is not installed or its executable moved.") }
        let directory = try workspace(); defer { try? FileManager.default.removeItem(at: directory) }
        switch provider {
        case .claude:
            if !Self.recentlyConfirmed("claude:" + executable) { _ = try await claudeAccount(executable, directory); Self.confirm("claude:" + executable) }
            let output = try await run(executable, Self.claudeEditArguments(model: options.model, system: system, in: directory), in: directory, input: user, timeout: 100)
            let result = try object(output)
            guard result["is_error"] as? Bool != true, result["subtype"] as? String == "success", let text = result["result"] as? String else { throw VerbError("Claude could not complete cleanup. Check model access or your subscription limit. " + (result["result"] as? String ?? "")) }
            return text
        case .codex:
            // Metadata check prevents an API-authenticated CLI from consuming API credit.
            if !Self.recentlyConfirmed("codex:" + executable) {
                let metadata = try codex(executable, directory)
                do { _ = try await withTaskCancellationHandler { try await initializeCodex(metadata) } onCancel: { metadata.stop() }; metadata.stop() } catch { metadata.stop(); throw error }
                Self.confirm("codex:" + executable)
            }
            let schema = directory.appendingPathComponent("response-schema.json")
            try Data("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"],\"additionalProperties\":false}".utf8).write(to: schema)
            var args = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--model", options.model, "--json", "--output-schema", schema.path, "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0", "-c", "model_reasoning_effort=\"low\"", "-c", "analytics.enabled=false"]
            for feature in ["shell_tool", "unified_exec", "code_mode", "code_mode_host", "multi_agent", "multi_agent_v2", "hooks", "plugins", "apps"] { args += ["-c", "features.\(feature)=false"] }
            args += ["-"]
            let output = try await run(executable, args, in: directory, input: system + "\nReturn the edited dictation in the JSON text field.\nInput JSON:\n" + user, timeout: 100)
            var text: String?
            for line in output.components(separatedBy: .newlines) {
                guard let event = try? object(line) else { continue }
                if ["error", "turn.failed"].contains(event["type"] as? String ?? "") { throw VerbError("Codex could not finish cleanup. Check the selected model and your account's usage limits.") }
                if event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let value = item["text"] as? String { text = value }
            }
            guard let text, let result = try object(text)["text"] as? String else { throw VerbError("Codex did not return a complete edited transcript.") }
            return result
        case .cursor:
            return try await cursorEdit(executable, directory, model: options.model, prompt: system + "\nInput JSON:\n" + user)
        case .gemini:
            let child = try acpProcess(executable, directory, provider: .gemini); defer { child.stop() }
            return try await withTaskCancellationHandler {
                let session = try await initializeACP(child, directory: directory, provider: .gemini)
                guard let id = session["sessionId"] as? String, Self.acpModels(session).contains(where: { $0.id == options.model }) else { throw VerbError("This Gemini model is no longer available. Refresh the model list.") }
                if (session["configOptions"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == "model" }) == true {
                    _ = try await child.request("session/set_config_option", ["sessionId": id, "configId": "model", "value": options.model], id: 3)
                } else { _ = try await child.request("session/set_model", ["sessionId": id, "modelId": options.model], id: 3) }
                try child.send(["jsonrpc": "2.0", "id": 4, "method": "session/prompt", "params": ["sessionId": id, "prompt": [["type": "text", "text": system + "\nInput JSON:\n" + user]]]])
                var text = ""
                while true {
                    let event = try await child.next(); try child.denyRequest(event)
                    if event["method"] as? String == "session/update", let params = event["params"] as? [String: Any], let update = params["update"] as? [String: Any], update["sessionUpdate"] as? String == "agent_message_chunk", let content = update["content"] as? [String: Any], content["type"] as? String == "text" { text += content["text"] as? String ?? "" }
                    if event["id"] as? Int == 4, event["method"] == nil {
                        guard event["error"] == nil, let result = event["result"] as? [String: Any], result["stopReason"] as? String == "end_turn" else { throw VerbError("Gemini did not complete the edit. Check login, model access and quota.") }; return text
                    }
                }
            } onCancel: { child.stop() }
        case .copilot:
            return try await copilotEdit(executable, directory, model: options.model, system: system, user: user)
        }
    }
    private func cursorEdit(_ executable: String, _ directory: URL, model: String, prompt: String) async throws -> String {
        let status = try await run(executable, ["status"], in: directory)
        try Self.validateCursorLogin(status)
        let configDirectory = directory.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config: [String: Any] = ["permissions": ["allow": [], "deny": ["Shell(*)", "Read(**)", "Read(/**)", "Write(**)", "Write(/**)", "WebFetch(*)", "Mcp(*:*)"]]]
        try JSONSerialization.data(withJSONObject: config).write(to: configDirectory.appendingPathComponent("cli.json"))
        let output = try await run(executable, ["--print", "--mode", "ask", "--model", model, "--output-format", "json", "--workspace", directory.path, "--sandbox", "enabled"], in: directory, input: prompt, timeout: 100)
        let result = try object(output)
        guard result["is_error"] as? Bool != true, let text = (result["result"] ?? result["text"]) as? String else { throw VerbError("Cursor did not return a complete edit. Check the CLI version, login and usage limits.") }
        return text
    }
    private func copilotEdit(_ executable: String, _ directory: URL, model: String, system: String, user: String) async throws -> String {
        let child = try copilot(executable, directory); defer { child.stop() }
        return try await withTaskCancellationHandler {
            _ = try HarnessPolicy.subscriptionAccount(.copilot, await copilotAccount(child))
            let options: [String: Any] = ["model": model, "clientName": "Verb", "workingDirectory": directory.path, "systemMessage": ["mode": "replace", "content": system], "availableTools": [], "toolFilterPrecedence": "excluded", "mcpServers": [:], "customAgents": [], "requestPermission": true, "requestUserInput": false, "enableSessionTelemetry": false, "enableSessionStore": false, "enableFileHooks": false, "enableHostGitOperations": false, "enableSkills": false, "enableOnDemandInstructionDiscovery": false, "customAgentsLocalOnly": true, "enableConfigDiscovery": false, "mcpOAuthTokenStorage": "in-memory", "skipEmbeddingRetrieval": true, "embeddingCacheStorage": "in-memory", "memory": ["enabled": false], "streaming": false]
            let session = try await child.request("session.create", options, id: 2)
            guard let id = session["sessionId"] as? String else { throw VerbError("Copilot could not start a text-only session.") }
            _ = try await child.request("session.options.update", ["sessionId": id, "skipCustomInstructions": true, "customAgentsLocalOnly": true, "coauthorEnabled": false, "manageScheduleEnabled": false, "installedPlugins": [], "includedBuiltinSkills": []], id: 4)
            try child.send(["jsonrpc": "2.0", "id": 3, "method": "session.send", "params": ["sessionId": id, "prompt": user]])
            var text = ""
            while true {
                let event = try await child.next(); try child.denyRequest(event)
                if event["error"] != nil { throw VerbError("Copilot could not complete this edit. Check your account, model access and credits.") }
                guard let params = event["params"] as? [String: Any] else { continue }
                let value = params["event"] as? [String: Any] ?? params
                let type = value["type"] as? String ?? "", data = value["data"] as? [String: Any] ?? [:]
                if type == "assistant.message", let content = data["content"] as? String { text = content }
                if type == "permission.requested" { throw VerbError("Copilot requested a tool. Verb only accepts text-only cleanup.") }
                if type == "session.error" { throw VerbError("Copilot: " + (data["message"] as? String ?? "Edit failed")) }
                if type == "session.idle" { return text }
            }
        } onCancel: { child.stop() }
    }
}
