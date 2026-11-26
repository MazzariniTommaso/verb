import AppKit
import VerbCore

/// Checks the limits of the main window and the notepad in real windows, on the main screen but
/// invisible, with a throwaway profile and no microphone, keyboard tap or model:
///
///     .build/release/Verb --check-window /path/to/result.txt
///
/// Each window takes the smallest and largest sizes its screen has room for; a size given from
/// outside a drag, too large or too small, comes back within them; the green button makes it as
/// large as it may be, never full screen. The sidebar's icons stand on the middle of the window's
/// buttons. What happened is written to the file, and Verb quits.
@MainActor enum WindowCheck {
    static func run(_ delegate: AppDelegate, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verb-window-check-" + UUID().uuidString, isDirectory: true)
        guard let model = try? AppModel(dataDirectory: root, services: false), let screen = NSScreen.main else { NSApp.terminate(nil); return }
        delegate.model = model
        var lines: [String] = [], failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            if !passed { failures += 1 }
            lines.append((passed ? "ok    " : "FAIL  ") + label + (detail.isEmpty ? "" : " · " + detail))
        }
        func after(_ seconds: Double, _ step: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(step) } }
        func size(_ window: NSWindow) -> CGSize { window.contentRect(forFrameRect: window.frame).size }
        func near(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1 }
        func text(_ size: CGSize) -> String {
            func side(_ value: CGFloat) -> String { value > 100_000 ? "none" : "\(Int(value.rounded()))" }
            return "\(side(size.width)) × \(side(size.height))"
        }
        func show(_ window: NSWindow) {
            window.alphaValue = 0
            window.setFrameOrigin(screen.visibleFrame.origin)
            window.orderFrontRegardless()
        }

        let main = delegate.makeMainWindow(model)
        delegate.window = main
        let notes = delegate.makeNotesWindow(model)
        // The sizes tried here are never saved as the notepad's frame.
        notes.setFrameAutosaveName("")
        delegate.notesWindow = notes
        show(main); show(notes)

        /// One window through its steps, then `next`.
        func walk(_ name: String, _ window: NSWindow, _ wanted: WindowLayout.Limits, then next: @escaping @MainActor () -> Void) {
            let limits = WindowLayout.limits(wanted, room: window.contentRect(forFrameRect: screen.visibleFrame).size)
            check("\(name): has a smallest and a largest size", near(window.contentMinSize, wanted.min) && near(window.contentMaxSize, wanted.max),
                  "from \(text(window.contentMinSize)) to \(text(window.contentMaxSize)), room on this screen \(text(window.contentRect(forFrameRect: screen.visibleFrame).size))")
            check("\(name): never full screen", window.collectionBehavior.contains(.fullScreenNone))
            window.setContentSize(CGSize(width: 5000, height: 4000))
            after(0.3) {
                check("\(name): a size too large comes back to the largest", near(size(window), limits.max), text(size(window)))
                window.setContentSize(CGSize(width: 200, height: 150))
                after(0.3) {
                    check("\(name): a size too small comes back to the smallest", near(size(window), limits.min), text(size(window)))
                    window.zoom(nil)
                    after(0.6) {
                        check("\(name): the green button makes it as large as it may be", near(size(window), limits.max), text(size(window)))
                        next()
                    }
                }
            }
        }

        after(0.5) {
            // The sidebar with its icons alone is as wide as the window's buttons need, the same
            // margin on both sides; the whole sidebar holds them with room to spare.
            delegate.measureWindowButtons()
            let buttons = model.windowButtons.frame, rail = model.windowButtons.railWidth
            check("main window: the icon sidebar centres the window's buttons", abs((rail - buttons.maxX) - buttons.minX) <= 1,
                  "buttons \(Int(buttons.minX))–\(Int(buttons.maxX)) pt, sidebar \(Int(rail)) pt")
            check("main window: the whole sidebar holds the window's buttons", buttons.maxX + buttons.minX <= Sizing.sidebar, "sidebar \(Int(Sizing.sidebar)) pt")
            walk("main window", main, AppDelegate.mainLimits) {
                walk("notepad", notes, AppDelegate.notepadLimits) {
                    lines.append(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
                    try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
                    main.orderOut(nil); notes.orderOut(nil)
                    try? FileManager.default.removeItem(at: root)
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
