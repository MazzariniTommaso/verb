import Foundation

public enum HarnessProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, gemini, copilot
    public var id: String { rawValue }
    public var title: String { switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .cursor: return "Cursor Agent"; case .gemini: return "Gemini CLI"; case .copilot: return "GitHub Copilot" } }
    public var commands: [String] { switch self { case .claude: return ["claude"]; case .codex: return ["codex"]; case .cursor: return ["cursor-agent", "agent"]; case .gemini: return ["gemini"]; case .copilot: return ["copilot"] } }
    public var loginCommand: String { switch self { case .claude: return "claude auth login"; case .codex: return "codex login"; case .cursor: return "agent login"; case .gemini: return "gemini"; case .copilot: return "copilot login" } }
    public var documentation: URL { URL(string: { switch self { case .claude: return "https://code.claude.com/docs/en/setup"; case .codex: return "https://developers.openai.com/codex/cli/"; case .cursor: return "https://cursor.com/docs/cli/installation"; case .gemini: return "https://geminicli.com/docs/get-started/authentication/"; case .copilot: return "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli" } }())! }
    public var billingNote: String {
        switch self {
        case .claude: return "Uses the Claude Code subscription login. Print-mode requests consume your plan's limits; any enabled extra usage is governed by Anthropic."
        case .codex: return "Uses the CLI's ChatGPT login. Requests consume Codex plan limits; additional credits follow your account settings. API-key login is blocked here."
        case .cursor: return "Uses Cursor's CLI login. Model requests can consume included usage or enabled on-demand usage. A Cursor subscription does not make every model unlimited."
        case .gemini: return "Uses Google login in Gemini CLI. Model access and quotas depend on the signed-in account and plan. API-key and Vertex routes are disabled here."
        case .copilot: return "Uses GitHub Copilot's saved login. Requests can consume your plan's AI credits; additional spending follows your GitHub settings."
        }
    }
}
public struct HarnessPreferences: Codable, Equatable, Sendable {
    public var provider: HarnessProvider = .claude
    public var models: [String: String] = [:]
    public var executables: [String: String] = [:]
    public init() {}
    public var model: String { get { models[provider.rawValue] ?? "" } set { models[provider.rawValue] = newValue } }
    public var executable: String { get { executables[provider.rawValue] ?? "" } set { executables[provider.rawValue] = newValue } }
}
public struct HarnessModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var resolvedID: String?
    public init(id: String, name: String, detail: String = "", resolvedID: String? = nil) { self.id = id; self.name = name; self.detail = detail; self.resolvedID = resolvedID }
}
public struct HarnessCatalog: Codable, Equatable, Sendable {
    public var provider: HarnessProvider
    public var executable: String
    public var models: [HarnessModel]
    public var account: String
    public var source: String
    public var fetchedAt: Date
    public init(provider: HarnessProvider, executable: String, models: [HarnessModel], account: String, source: String, fetchedAt: Date = Date()) {
        self.provider = provider; self.executable = executable; self.models = models; self.account = account; self.source = source; self.fetchedAt = fetchedAt
    }
}
public enum HarnessPolicy {
    public static func validateModel(_ model: String) throws {
        guard !model.isEmpty, model.count <= 180, !model.hasPrefix("-"), !model.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw VerbError("Choose a model from the provider's current list.") }
    }
    public static func requireCloud(_ settings: Settings) throws {
        guard settings.allowRemoteProcessing else { throw VerbError("Remote processing is off. Enable it before sending text to a subscription CLI.") }
        try validateModel(settings.harnessOptions.model)
    }
    public static func subscriptionAccount(_ provider: HarnessProvider, _ data: [String: Any]) throws -> String {
        switch provider {
        case .claude:
            guard data["loggedIn"] as? Bool == true, data["authMethod"] as? String == "claude.ai", data["apiProvider"] as? String == "firstParty", let plan = data["subscriptionType"] as? String, !plan.isEmpty else { throw VerbError("Sign in to Claude Code with your Claude subscription. API-key or third-party billing is not used by this connection.") }
            return "Claude subscription · " + plan
        case .codex:
            guard data["type"] as? String == "chatgpt" else { throw VerbError("Sign in with ChatGPT using codex login. API-key, token and external-provider billing are blocked in subscription mode.") }
            return "ChatGPT subscription"
        case .copilot:
            guard data["isAuthenticated"] as? Bool == true else { throw VerbError("Sign in to GitHub Copilot in its CLI, then refresh.") }
            return "GitHub Copilot login"
        default: return "Saved CLI login"
        }
    }
}
