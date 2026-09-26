import AppKit
import VerbCore

/// Checks the notepad window's buttons and ⌃⌥N, with sample data and no microphone,
/// keyboard tap or shortcut:
///
///     open -n -g release/Verb.app --args --check-notepad /path/to/result.txt
///
/// The notepad opens, is minimised to the Dock, comes back as ⌃⌥N brings it, closes as
/// ⌃⌥N closes it, and opens again. What happened is written to the file, and Verb quits.
@MainActor enum NotepadCheck {
    static func run(_ delegate: AppDelegate, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verb-notepad-check-" + UUID().uuidString, isDirectory: true)
        guard let model = try? AppModel(dataDirectory: root, services: false) else { NSApp.terminate(nil); return }
        delegate.model = model
        var lines: [String] = []
        func note(_ text: String) { lines.append(text) }
        func state(_ label: String) {
            guard let window = delegate.notesWindow else { note("\(label): no window"); return }
            note("\(label): visible \(window.isVisible), key \(window.isKeyWindow), minimised \(window.isMiniaturized), dock icon \(NSApp.activationPolicy() == .regular)")
        }
        func after(_ seconds: Double, _ step: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(step) } }
        delegate.toggleNotepad()
        after(0.8) {
            state("opened with ⌃⌥N")
            if let window = delegate.notesWindow {
                let buttons: [(String, NSWindow.ButtonType)] = [("close", .closeButton), ("minimise", .miniaturizeButton), ("zoom", .zoomButton)]
                note("buttons: " + buttons.map { "\($0.0) \(window.standardWindowButton($0.1)?.isEnabled == true ? "on" : "off")" }.joined(separator: ", "))
                note("floats over other apps: \(window.level == .floating)")
                window.miniaturize(nil)
            }
            after(1.2) {
                state("after minimise")
                delegate.toggleNotepad()
                after(1.2) {
                    state("⌃⌥N while minimised")
                    delegate.toggleNotepad()
                    after(0.8) {
                        state("⌃⌥N while in front")
                        delegate.toggleNotepad()
                        after(0.8) {
                            state("⌃⌥N after closing")
                            delegate.notesWindow?.close()
                            try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
                            try? FileManager.default.removeItem(at: root)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }
}
