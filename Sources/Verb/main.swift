import AppKit
import SwiftUI
import VerbCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    var window: NSWindow?
    var overlay: OverlayPanel?
    var preview: OverlayPanel?
    let hover = OverlayHover()
    var menuBar: MenuBarController?
    var notesWindow: NSWindow?
    private let notesDelegate = NotesWindowDelegate()
    var hideTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // A tool flag without its file would otherwise start a second Verb, keys and microphone included.
        for flag in ["--render-snapshots", "--probe-fields", "--check-notepad", "--check-welcome", "--measure-frames", "--data-dir"] {
            if let index = arguments.firstIndex(of: flag), index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
                FileHandle.standardError.write(Data("\(flag) needs a path after it.\n".utf8)); exit(64)
            }
        }
        if let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count {
            Snapshots.render(to: URL(fileURLWithPath: arguments[index + 1])); NSApp.terminate(nil); return
        }
        if let index = arguments.firstIndex(of: "--probe-fields"), index + 1 < arguments.count {
            FieldProbe.run(output: URL(fileURLWithPath: arguments[index + 1]), wake: arguments.contains("--wake")); return
        }
        if let index = arguments.firstIndex(of: "--check-notepad"), index + 1 < arguments.count {
            NotepadCheck.run(self, output: URL(fileURLWithPath: arguments[index + 1])); return
        }
        if let index = arguments.firstIndex(of: "--check-welcome"), index + 1 < arguments.count {
            WelcomeCheck.run(self, output: URL(fileURLWithPath: arguments[index + 1])); return
        }
        if let index = arguments.firstIndex(of: "--measure-frames"), index + 1 < arguments.count {
            FrameProbe.run(output: URL(fileURLWithPath: arguments[index + 1])); return
        }
        let launchedAtLogin = Self.launchedAsLoginItem()
        let dataDirectory = arguments.firstIndex(of: "--data-dir").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        if let dataDirectory { Secrets.useProfile(dataDirectory) }
        do { model = try AppModel(dataDirectory: dataDirectory) }
        catch {
            // The settings, and so the chosen language, are what couldn't be read: the Mac's language it is.
            let t = Lang(language: Locale.preferredLanguages.first?.hasPrefix("it") == true ? .italian : .english)
            let alert = NSAlert(); alert.messageText = t("Verb can’t open its data", "Verb non riesce ad aprire i suoi dati"); alert.informativeText = t.message(error.localizedDescription)
            alert.addButton(withTitle: t("Quit Verb", "Esci da Verb"))
            alert.runModal(); NSApp.terminate(nil); return
        }
        guard let model else { return }
        applyAppearance()
        // The first time, the window opens on the welcome; `--welcome` shows it again.
        if !model.settings.onboardingComplete || arguments.contains("--welcome") { model.welcome = .hello }

        let window = makeMainWindow(model)
        window.setFrameAutosaveName("VerbMainWindow"); window.center()
        self.window = window

        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Sizing.overlayWidth, height: Sizing.overlayHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovableByWindowBackground = true
        // The panel fits around the overlay, whose size depends on the style and on what it shows.
        let host = OverlayHostingView(rootView: OverlayRoot(meter: model.meter) { [weak self] size in DispatchQueue.main.async { self?.fitOverlay(to: size) } }
            .environmentObject(model).environmentObject(hover))
        host.hover = hover
        panel.contentView = host
        overlay = panel

        // The words as they are spoken, above the capsule. It never takes a click.
        let preview = OverlayPanel(contentRect: NSRect(origin: .zero, size: LivePreviewView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        preview.isOpaque = false; preview.backgroundColor = .clear; preview.hasShadow = false; preview.level = .floating
        preview.ignoresMouseEvents = true; preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        preview.contentView = NSHostingView(rootView: LivePreviewView().environmentObject(model))
        self.preview = preview

        let menuBar = MenuBarController(model: model)
        menuBar.showWindow = { [weak self] in self?.showMainWindow() }
        menuBar.showPage = { [weak self] page in self?.show(page) }
        menuBar.showNotepad = { [weak self] in self?.toggleNotepad(forceOpen: true) }
        self.menuBar = menuBar

        model.showWindow = { [weak self] in self?.showMainWindow() }
        model.phaseChanged = { [weak self] in self?.updateOverlay() }
        model.flashOutcome = { [weak self] in self?.flashOverlay() }
        model.menuChanged = { [weak self] in self?.menuBar?.refreshIcon() }
        model.toggleNotepad = { [weak self] in self?.toggleNotepad() }
        model.interfaceChanged = { [weak self] in self?.applyAppearance(); self?.installMainMenu(); self?.menuBar?.refreshIcon() }
        installMainMenu()

        // At login, and with --background, Verb waits in the menu bar. It still opens the
        // window when something needed for dictation is missing, so setup is never hidden.
        let quiet = arguments.contains("--background") || launchedAtLogin
        if quiet && model.readyForBackground { NSApp.setActivationPolicy(.accessory) } else { showMainWindow() }
    }

    /// The window with the sidebar and the pages, or the welcome while it is on.
    func makeMainWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Verb"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSPalette.surfacePage
        window.minSize = NSSize(width: 900, height: 680); window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSHostingController(rootView: MainView().environmentObject(model))
        // The window keeps its own size; otherwise SwiftUI would shrink it to the view's minimum.
        content.sizingOptions = []
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1080, height: 780))
        return window
    }

    /// True when macOS opened Verb as a login item rather than because someone launched it.
    static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applyAppearance() {
        switch model?.settings.interfaceOptions.appearance ?? .automatic {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func installMainMenu() {
        guard let model else { return }
        let t = model.lang
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("About Verb", "Informazioni su Verb"), action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("Settings…", "Impostazioni…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("Hide Verb", "Nascondi Verb"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: t("Hide Others", "Nascondi altre"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: t("Show All", "Mostra tutte"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("Quit Verb", "Esci da Verb"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let editMenu = NSMenu(title: t("Edit", "Composizione"))
        for (title, action, key) in [(t("Undo", "Annulla"), Selector(("undo:")), "z"), (t("Redo", "Ripeti"), Selector(("redo:")), "Z"), (t("Cut", "Taglia"), #selector(NSText.cut(_:)), "x"),
                                     (t("Copy", "Copia"), #selector(NSText.copy(_:)), "c"), (t("Paste", "Incolla"), #selector(NSText.paste(_:)), "v"), (t("Select All", "Seleziona tutto"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; main.addItem(editItem)

        // Cmd-W closes the window; Verb keeps running in the menu bar.
        let windowMenu = NSMenu(title: t("Window", "Finestra"))
        windowMenu.addItem(withTitle: t("Close Window", "Chiudi la finestra"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: t("Minimize", "Contrai"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: t("Zoom", "Ridimensiona"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)

        let helpMenu = NSMenu(title: t("Help", "Aiuto"))
        helpMenu.addItem(withTitle: t("Take the Tour", "Fai il tour"), action: #selector(takeTour), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: t("Welcome to Verb…", "Introduzione a Verb…"), action: #selector(showWelcome), keyEquivalent: "").target = self
        let helpItem = NSMenuItem(); helpItem.submenu = helpMenu; main.addItem(helpItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    /// Bumped whenever the overlay is asked to show, so a fade-out that finishes late never hides a new session.
    private var overlayGeneration = 0
    func updateOverlay() {
        guard let model else { return }
        hideTask?.cancel()
        menuBar?.refreshIcon()
        if model.busy {
            overlayGeneration += 1
            showOverlay(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            scheduleHide()
        }
    }

    /// Shows the last outcome for a moment although nothing runs, as after the copy key.
    func flashOverlay() {
        guard let model, !model.busy else { return }
        hideTask?.cancel()
        overlayGeneration += 1
        showOverlay(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        scheduleHide()
    }

    private func showOverlay(reduceMotion: Bool) {
        guard let overlay else { return }
        if !overlay.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame { overlay.setFrameOrigin(NSPoint(x: (frame.midX - overlay.frame.width / 2).rounded(), y: frame.minY + 38)) }
            hover.inside = overlay.frame.contains(mouse)
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            // Attached as a child, the card follows the overlay when it is dragged.
            if let preview {
                placePreview()
                preview.alphaValue = 1
                preview.orderFrontRegardless(); overlay.addChildWindow(preview, ordered: .above)
            }
            // It fades in where it stays: the panel changes size with what it shows, and a rise would fight that.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? Motion.fast : Motion.slow; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in context.duration = Motion.fast; overlay.animator().alphaValue = 1 }
        }
    }

    private func scheduleHide() {
        guard let overlay else { return }
        let generation = overlayGeneration
        hideTask = Task { [weak self, weak overlay] in
            // A failure stays long enough to read what to do next; a cancel, while it can be restored.
            let linger = self?.model?.pendingSuggestion != nil ? 10 : self?.model?.outcome == .failed ? Motion.lingerFailure : self?.model?.restorable != nil ? CancelledDictation.window - 2 : Motion.linger
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            // Under the pointer, Restore stays until it is no longer on offer.
            while !Task.isCancelled, self?.hover.inside == true, self?.model?.restorable != nil || self?.model?.pendingSuggestion != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, let self, let overlay, generation == self.overlayGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.base; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                overlay.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in
                guard generation == self.overlayGeneration else { return }
                if let preview = self.preview { overlay.removeChildWindow(preview); preview.orderOut(nil) }
                overlay.orderOut(nil)
                // A suggestion not answered in time waits on the Dictionary page.
                self.model?.pendingSuggestion = nil
            } })
        }
    }

    /// Fits the panel around the overlay, keeping its centre and its bottom edge where they are.
    func fitOverlay(to size: CGSize) {
        guard let overlay, size.width >= 1, size.height >= 1 else { return }
        let frame = overlay.frame
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            overlay.setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY, width: size.width, height: size.height), display: true)
            overlay.invalidateShadow()
        }
        placePreview()
    }
    /// The live preview card stands centred over the overlay, whatever its size.
    func placePreview() {
        guard let overlay, let preview else { return }
        preview.setFrameOrigin(NSPoint(x: (overlay.frame.midX - preview.frame.width / 2).rounded(), y: overlay.frame.maxY - LivePreviewView.overlap))
    }

    /// The notepad over the other apps. ⌃⌥N opens it where it was left, brings it back from the
    /// Dock when minimised, brings it forward when another window is in front, and closes it
    /// when it is the one in front. Its own buttons close, minimise and zoom it like any window.
    func toggleNotepad(forceOpen: Bool = false) {
        guard let model else { return }
        let window = notesWindow ?? makeNotesWindow(model)
        notesWindow = window
        window.title = model.lang("Notepad", "Blocco note")
        // While the notepad is open Verb has its Dock icon, where a minimised notepad waits.
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized {
            NSApp.activate(ignoringOtherApps: true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if !forceOpen, window.isVisible, window.isKeyWindow, NSApp.isActive { window.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeNotesWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // The title bar takes the paper's colour; the title stays, centred, as in any window.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSPalette.surfaceRaised
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.minSize = NSSize(width: 560, height: 380)
        let content = NSHostingController(rootView: NotesPanelView().environmentObject(model))
        content.sizingOptions = []
        window.contentViewController = content
        window.setContentSize(NSSize(width: 780, height: 560))
        if !window.setFrameUsingName("VerbNotepad") { window.center() }
        window.setFrameAutosaveName("VerbNotepad")
        // A main window in the Dock keeps Verb in the Dock too.
        notesDelegate.closed = { [weak self] in if self?.window?.isVisible != true && self?.window?.isMiniaturized != true { NSApp.setActivationPolicy(.accessory) } }
        window.delegate = notesDelegate
        return window
    }

    @objc func showMainWindow() { NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func openSettings() { show(.settings) }
    /// A page asked for from a menu: it closes the welcome, like Skip, and ends a tour.
    func show(_ page: Page) {
        guard let model else { return }
        if model.welcome != nil { model.finishWelcome(tour: false) }
        if model.tourStop != nil { model.endTour() }
        model.page = page; showMainWindow()
    }
    @objc func takeTour() { model?.startTour() }
    @objc func showWelcome() { model?.startWelcome() }
    @objc func about() {
        let t = model?.lang ?? Lang(language: .english)
        let serif = NSFont.systemFont(ofSize: 13).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0.withSymbolicTraits(.italic), size: 13) } ?? .systemFont(ofSize: 13)
        let credits = NSMutableAttributedString(string: "Verba volant, scripta manent.\n", attributes: [.font: serif, .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: t("Personal dictation for macOS, local first.", "Dettatura personale per macOS, prima di tutto in locale.") + "\nMLX Audio Swift · Parakeet · Qwen ASR · Ollama",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Verb", .applicationVersion: AppInfo.version, .version: "", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        // The Dock icon stays while the notepad is still open or waiting in the Dock.
        if notesWindow?.isVisible != true && notesWindow?.isMiniaturized != true { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

/// Tells Verb when the notepad closes, to put Verb back in the menu bar alone.
final class NotesWindowDelegate: NSObject, NSWindowDelegate {
    var closed: () -> Void = {}
    func windowWillClose(_ notification: Notification) { closed() }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // Verb lives in the menu bar; the Dock icon appears only while the window is open.
    application.setActivationPolicy(.accessory)
    application.run()
}
