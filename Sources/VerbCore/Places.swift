import Foundation

/// The kind of place a dictation goes: an email, a work chat, a chat with friends, or anything
/// else. Each kind can have a style of its own, which every app and site of that kind takes.
public enum AppCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case email, work, personal, other
    public var id: String { rawValue }
}

/// A website Verb recognises in a browser, so Gmail in Chrome is Gmail rather than Chrome.
public struct Site: Equatable, Sendable {
    /// Stable, for settings: "gmail", "slack".
    public let id: String
    public let name: String
    /// Hosts it answers on; a host matches when it is one of these or ends with "." and one.
    public let hosts: [String]
    public let category: AppCategory
    /// What its window titles end with, for a browser that doesn't say its address.
    public let titles: [String]
    public init(id: String, name: String, hosts: [String], category: AppCategory, titles: [String] = []) { self.id = id; self.name = name; self.hosts = hosts; self.category = category; self.titles = titles }
    /// The key its style is kept under, beside the apps' bundle identifiers.
    public var styleKey: String { Places.sitePrefix + id }
}

public enum Places {
    /// Styles for sites are kept under "web:" and the site's id.
    public static let sitePrefix = "web:"

    public static let sites: [Site] = [
        Site(id: "gmail", name: "Gmail", hosts: ["mail.google.com"], category: .email, titles: ["Gmail"]),
        Site(id: "outlook", name: "Outlook", hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com"], category: .email, titles: ["Outlook"]),
        Site(id: "yahoo-mail", name: "Yahoo Mail", hosts: ["mail.yahoo.com"], category: .email, titles: ["Yahoo Mail"]),
        Site(id: "proton-mail", name: "Proton Mail", hosts: ["mail.proton.me"], category: .email, titles: ["Proton Mail"]),
        Site(id: "icloud-mail", name: "iCloud Mail", hosts: ["icloud.com"], category: .email),
        Site(id: "slack", name: "Slack", hosts: ["app.slack.com"], category: .work, titles: ["Slack"]),
        Site(id: "teams", name: "Microsoft Teams", hosts: ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"], category: .work, titles: ["Microsoft Teams"]),
        Site(id: "linkedin", name: "LinkedIn", hosts: ["linkedin.com"], category: .work, titles: ["LinkedIn"]),
        Site(id: "jira", name: "Jira", hosts: ["atlassian.net"], category: .work),
        Site(id: "linear", name: "Linear", hosts: ["linear.app"], category: .work),
        Site(id: "whatsapp", name: "WhatsApp", hosts: ["web.whatsapp.com"], category: .personal, titles: ["WhatsApp"]),
        Site(id: "telegram", name: "Telegram", hosts: ["web.telegram.org"], category: .personal, titles: ["Telegram"]),
        Site(id: "messenger", name: "Messenger", hosts: ["messenger.com"], category: .personal, titles: ["Messenger"]),
        Site(id: "chatgpt", name: "ChatGPT", hosts: ["chatgpt.com", "chat.openai.com"], category: .other, titles: ["ChatGPT"]),
        Site(id: "claude", name: "Claude", hosts: ["claude.ai"], category: .other, titles: ["Claude"]),
        Site(id: "gemini", name: "Gemini", hosts: ["gemini.google.com"], category: .other, titles: ["Gemini"]),
        Site(id: "google-docs", name: "Google Docs", hosts: ["docs.google.com"], category: .other, titles: ["Google Docs", "Documenti Google"]),
        Site(id: "notion", name: "Notion", hosts: ["notion.so", "notion.site"], category: .other),
        Site(id: "github", name: "GitHub", hosts: ["github.com"], category: .other, titles: ["GitHub"]),
        Site(id: "x", name: "X", hosts: ["x.com", "twitter.com"], category: .other),
    ]

    /// Browsers, whose tab says where a dictation goes better than the app does.
    public static let browsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
                                               "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS"]

    /// The site at a host: "mail.google.com" is Gmail, "acme.atlassian.net" Jira.
    public static func site(host: String) -> Site? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sites.first { site in site.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }
    public static func site(url: URL) -> Site? { url.host.flatMap(site(host:)) }
    /// The site a window title names at its end, as "Inbox (3) - you@gmail.com - Gmail" does.
    public static func site(title: String) -> Site? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return sites.first { site in site.titles.contains { name in
            [" - ", " – ", " — ", " | ", " · "].contains { trimmed.hasSuffix($0 + name) } || trimmed == name
        } }
    }
    public static func site(id: String) -> Site? { sites.first { $0.id == id } }
    /// The site behind a style key, nil for an app's.
    public static func site(styleKey: String) -> Site? { styleKey.hasPrefix(sitePrefix) ? site(id: String(styleKey.dropFirst(sitePrefix.count))) : nil }

    static let email: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.freron.MailMate", "it.bloop.airmail2", "com.mimestream.Mimestream",
                                     "ch.protonmail.desktop", "io.canarymail.mac", "com.postbox-inc.postbox", "org.mozilla.thunderbird"]
    static let work: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.linear", "com.atlassian.trello", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]
    static let personal: Set<String> = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.hnc.Discord", "jp.naver.line.mac"]

    /// The kind of an app, or of the site it shows.
    public static func category(bundleID: String, site: Site? = nil) -> AppCategory {
        if let site { return site.category }
        if email.contains(bundleID) { return .email }
        if work.contains(bundleID) { return .work }
        if personal.contains(bundleID) { return .personal }
        return .other
    }
}

/// How a text with Markdown goes in: formatted where formatting is kept, as plain words in a
/// chat, as written where Markdown is the language (editors, terminals, notes in Markdown, AI chats).
public enum PasteFormat: Equatable, Sendable {
    case rich, plain, raw

    static let richApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.apple.iWork.Pages", "com.microsoft.Word", "com.apple.Notes", "com.apple.TextEdit", "notion.id",
                                    "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.readdle.smartemail-Mac", "com.microsoft.onenote.mac", "com.evernote.Evernote", "com.google.drivefs"]
    static let markdown: Set<String> = ["md.obsidian", "net.shinyfrog.bear", "pro.writer.mac", "abnerworks.Typora", "com.uranusjr.macdown", "com.logseq.logseq", "com.anthropic.claudefordesktop", "com.openai.chat"]
    static let richSites: Set<String> = ["gmail", "outlook", "yahoo-mail", "proton-mail", "icloud-mail", "google-docs", "notion", "slack", "teams", "linkedin", "jira"]
    static let markdownSites: Set<String> = ["github", "chatgpt", "claude", "gemini", "linear"]

    /// `code` is an editor or a terminal.
    public static func choose(bundleID: String, site: Site?, code: Bool) -> PasteFormat {
        if code { return .raw }
        if let site {
            if markdownSites.contains(site.id) { return .raw }
            if richSites.contains(site.id) { return .rich }
            return .plain
        }
        if markdown.contains(bundleID) { return .raw }
        if richApps.contains(bundleID) { return .rich }
        return .plain
    }
}
