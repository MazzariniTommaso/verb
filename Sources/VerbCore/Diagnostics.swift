import Foundation

/// A problem report: what you wrote, and what helps to find the cause, without anything
/// private. No dictations, no dictionary, no keys, no addresses beyond a server's host.
public enum Diagnostics {
    /// The settings that shape a dictation, as lines "name: value".
    public static func settingsSummary(_ settings: Settings) -> [String] {
        func host(_ address: String) -> String { URL(string: address)?.host ?? "custom" }
        var lines = [
            "speech: " + (settings.speechProvider == .onDevice ? "on this Mac, \(settings.localModel)" : "server at \(host(settings.speechEndpoint)), \(settings.speechModel)"),
            "language: \(settings.language.rawValue)",
        ]
        switch settings.cleanupProvider {
        case .local: lines.append("writing: Ollama on this Mac, \(settings.cleanupModel)")
        case .endpoint: lines.append("writing: server at \(host(settings.cleanupEndpoint)), \(settings.hostedCleanupModel)")
        case .harness: lines.append("writing: \(settings.harnessOptions.provider.rawValue) CLI, \(settings.harnessOptions.model)")
        case .off: lines.append("writing: off")
        }
        lines += [
            "refine: \(settings.cleanupPolicy.rawValue), style \(settings.style.rawValue), \(settings.appStyles.count) app styles",
            "overlay: \(settings.overlayStyle.rawValue), live words \(settings.livePreview ? "on" : "off")",
            "microphone: " + (settings.microphoneID.isEmpty ? "automatic" + (settings.preferBuiltInMic ? ", Mac first" : ", headphones first") : "chosen"),
            "voice: wake \(settings.voiceOptions.wakeWord ? "on" : "off"), stop commands \(settings.voiceOptions.stopCommands ? "on" : "off")",
            "keys: dictation \(settings.keyOptions.dictation?.label ?? "none"), command \(settings.keyOptions.voiceEdit?.label ?? "none")",
            "history: \(settings.retention.rawValue) days, audio \(settings.keepAudio ? "kept" : "not kept"), remote \(settings.allowRemoteProcessing ? "allowed" : "off")",
        ]
        return lines
    }

    /// The report as Markdown: your words, then the details under their own heading.
    public static func report(description: String, version: String, system: String, hardware: String, settings: Settings, log: [String] = []) -> String {
        var parts = [description.trimmingCharacters(in: .whitespacesAndNewlines), "### Details", "- Verb \(version)", "- \(system), \(hardware)"]
        parts += settingsSummary(settings).map { "- " + $0 }
        if !log.isEmpty { parts += ["### Recent log", "```", log.suffix(200).joined(separator: "\n"), "```"] }
        return parts.joined(separator: "\n")
    }

    /// A new issue on GitHub with the title and the report filled in. A long report is cut, as
    /// the address has a limit; the whole one is saved as a file to attach.
    public static func issueURL(title: String, body: String, repository: String = "MazzariniTommaso/verb") -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        let trimmed = body.count > 6000 ? String(body.prefix(6000)) + "\n…" : body
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: trimmed)]
        return components?.url
    }
}
