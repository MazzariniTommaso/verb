import AppKit
import ApplicationServices
import VerbCore

/// Editors and terminals, where Verb turns spoken names into code, and the project each one
/// has open: from the document in the front window, or its title.
@MainActor enum CodeApps {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                                         "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
    static let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.apple.dt.Xcode",
                                       "com.sublimetext.4", "com.sublimetext.3", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.panic.Nova", "com.barebones.bbedit", "com.google.android.studio"]
    static func isCode(_ bundleID: String) -> Bool { terminals.contains(bundleID) || editors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") }

    /// Where people keep their projects, to find one named in a window's title.
    private static let places = ["Projects", "Developer", "code", "Code", "src", "dev", "Documents/GitHub", "GitHub", "work", "repos", "Sites"]

    /// The project open in the app's front window.
    static func projectRoot(pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = TextTarget.attribute(app, kAXFocusedWindowAttribute) ?? TextTarget.attribute(app, kAXMainWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        // VS Code, Xcode and Sublime name the open file; Terminal names its folder.
        if let document = TextTarget.attribute(window, kAXDocumentAttribute) as? String, let url = URL(string: document), url.isFileURL,
           FileManager.default.fileExists(atPath: url.path) { return CodeSpeech.root(of: url) }
        guard let title = TextTarget.attribute(window, kAXTitleAttribute) as? String else { return nil }
        return root(fromTitle: title)
    }

    /// "~/Projects/Verb", or "AppModel.swift — Verb", as a folder that exists.
    static func root(fromTitle title: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let match = title.range(of: #"(~|/)[^\s—–:()]+"#, options: .regularExpression) {
            let path = String(title[match]).replacingOccurrences(of: "~", with: home.path, options: .anchored)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) { return CodeSpeech.root(of: URL(fileURLWithPath: path, isDirectory: isFolder.boolValue)) }
        }
        let names = title.components(separatedBy: CharacterSet(charactersIn: "—–")).flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("/") && $0.count <= 80 }
        for name in names.reversed() {
            for place in places {
                let folder = home.appendingPathComponent(place).appendingPathComponent(name, isDirectory: true)
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue { return CodeSpeech.root(of: folder) ?? folder }
            }
        }
        return nil
    }
}

/// A project Verb has read, and when.
struct CodeProject {
    var index: CodeSpeech.Index?
    var read: Date
}
