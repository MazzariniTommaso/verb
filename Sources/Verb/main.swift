import AppKit
import Combine
import SwiftUI
import VerbCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    var window: NSWindow?
    private var pageWatch: AnyCancellable?
    var overlay: OverlayPanel?
    private var styleWatch: AnyCancellable?
    let hover = OverlayHover()
    var menuBar: MenuBarController?
    var notesWindow: NSWindow?
    private let notesDelegate = NotesWindowDelegate()
    var hideTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // A tool flag without its file would otherwise start a second Verb, keys and microphone included.
        for flag in ["--render-snapshots", "--probe-fields", "--check-notepad", "--check-welcome", "--check-window", "--measure-frames", "--data-dir"] {
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
        if let index = arguments.firstIndex(of: "--check-window"), index + 1 < arguments.count {
            WindowCheck.run(self, output: URL(fileURLWithPath: arguments[index + 1])); return
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
        // A welcome left part way carries on from where it was.
        if arguments.contains("--welcome") { model.welcome = .hello }
        else if !model.settings.onboardingComplete { model.welcome = model.welcomeResume }

        let window = makeMainWindow(model)
        window.setFrameAutosaveName("VerbMainWindow"); window.center()
        // A size saved on a larger screen, or before the limits, comes within them.
        window.keep(within: Self.mainLimits)
        self.window = window
        measureWindowButtons()
        // On another screen, or one that changed, each window takes the limits it has room for.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepWindowsWithinLimits() }
        }
        // A display connected, removed or set to another resolution: the windows fit again, and the
        // island measures the notch, or its absence, where it now is.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepWindowsWithinLimits(); self?.placeOverlayAgain() }
        }
        // Another app in front has other menus: the room beside the notch is measured again.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureMenuRoom() }
        }

        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Sizing.overlayWidth, height: Sizing.overlayHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovableByWindowBackground = true
        // The panel fits around the overlay, whose size depends on the style and on what it shows.
        let host = OverlayHostingView(rootView: OverlayRoot(meter: model.meter) { [weak self] size in DispatchQueue.main.async { self?.fitOverlay(to: size) } }
            .environmentObject(model).environmentObject(hover))
        host.hover = hover
        panel.contentView = host
        overlay = panel

        // The notch style stays at the top between dictations; any other style hides.
        styleWatch = model.$settings.map { "\($0.overlayStyle.rawValue)|\($0.notchAtRest)" }.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.placeOverlayAgain() } }

        let menuBar = MenuBarController(model: model)
        menuBar.showWindow = { [weak self] in self?.showMainWindow() }
        menuBar.showPage = { [weak self] page in self?.show(page) }
        menuBar.showNotepad = { [weak self] in self?.toggleNotepad(forceOpen: true) }
        self.menuBar = menuBar

        model.showWindow = { [weak self] in self?.showMainWindow() }
        model.windowInView = { [weak self] in NSApp.isActive && self?.window?.isVisible == true && self?.window?.isMiniaturized == false }
        model.phaseChanged = { [weak self] in self?.updateOverlay() }
        model.flashOutcome = { [weak self] in self?.flashOverlay() }
        model.menuChanged = { [weak self] in self?.menuBar?.refreshIcon() }
        model.toggleNotepad = { [weak self] in self?.toggleNotepad() }
        model.interfaceChanged = { [weak self] in self?.applyAppearance(); self?.installMainMenu(); self?.menuBar?.refreshIcon(); self?.titleWindow() }
        // The window says which page it shows, for VoiceOver and the Window menu.
        pageWatch = model.$page.sink { [weak self] page in DispatchQueue.main.async { self?.titleWindow(page) } }
        // Increase Contrast switched on or off while Verb runs.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        installMainMenu()

        // At login, and with --background, Verb waits in the menu bar. It still opens the
        // window when something needed for dictation is missing, so setup is never hidden.
        let quiet = arguments.contains("--background") || launchedAtLogin
        if quiet && model.readyForBackground { NSApp.setActivationPolicy(.accessory) } else { showMainWindow() }
        if model.keepsDrop { placeOverlayAgain() }
    }

    /// The main window from half a laptop's screen, so it tiles beside another app, to the size
    /// past which a page only gains empty margins. The notepad, smaller, floats over other apps.
    static let mainLimits = WindowLayout.Limits(min: CGSize(width: Sizing.windowMinWidth, height: Sizing.windowMinHeight), max: CGSize(width: Sizing.windowMaxWidth, height: Sizing.windowMaxHeight))
    static let notepadLimits = WindowLayout.Limits(min: CGSize(width: Sizing.notepadMinWidth, height: Sizing.notepadMinHeight), max: CGSize(width: Sizing.notepadMaxWidth, height: Sizing.notepadMaxHeight))

    func keepWindowsWithinLimits() {
        window?.keep(within: Self.mainLimits)
        notesWindow?.keep(within: Self.notepadLimits)
    }

    /// The window with the sidebar and the pages, or the welcome while it is on.
    func makeMainWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Verb"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSPalette.surfacePage
        window.isReleasedWhenClosed = false; window.delegate = self
        // The green button makes it as large as it may be, rather than full screen past its largest.
        window.collectionBehavior.insert(.fullScreenNone)
        // The window takes its smallest and largest sizes from its view, which holds the limits;
        // not its ideal size, or SwiftUI would shrink the window to its minimum.
        let content = NSHostingController(rootView: MainView().environmentObject(model).frame(limits: Self.mainLimits))
        content.sizingOptions = [.minSize, .maxSize]
        // The view runs under the title bar, so its limits are the whole window's.
        content.safeAreaRegions = []
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1080, height: 780))
        window.keep(within: Self.mainLimits)
        return window
    }

    /// True when macOS opened Verb as a login item rather than because someone launched it.
    static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Light or Dark as chosen; with Increase Contrast on, their stronger versions.
    func applyAppearance() {
        let more = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch model?.settings.interfaceOptions.appearance ?? .automatic {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: more ? .accessibilityHighContrastAqua : .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: more ? .accessibilityHighContrastDarkAqua : .darkAqua)
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

        let viewMenu = NSMenu(title: t("View", "Vista"))
        let sidebarItem = viewMenu.addItem(withTitle: t("Show Only Icons in Sidebar", "Mostra solo le icone nella barra laterale"), action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.control, .command]; sidebarItem.target = self
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu; main.addItem(viewItem)

        // Every page from the keyboard, ⌘1 to ⌘8, in the sidebar's order.
        let goMenu = NSMenu(title: t("Go", "Vai"))
        for (index, page) in Page.allCases.enumerated() {
            let item = goMenu.addItem(withTitle: page.title(t), action: #selector(goToPage(_:)), keyEquivalent: "\(index + 1)")
            item.target = self; item.tag = index
        }
        let goItem = NSMenuItem(); goItem.submenu = goMenu; main.addItem(goItem)

        // Cmd-W closes the window; Verb keeps running in the menu bar.
        let windowMenu = NSMenu(title: t("Window", "Finestra"))
        windowMenu.addItem(withTitle: t("Close Window", "Chiudi la finestra"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: t("Minimize", "Contrai"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: t("Zoom", "Ridimensiona"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)

        let helpMenu = NSMenu(title: t("Help", "Aiuto"))
        helpMenu.addItem(withTitle: t("Take the Tour", "Fai il tour"), action: #selector(takeTour), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: t("Welcome to Verb…", "Introduzione a Verb…"), action: #selector(showWelcome), keyEquivalent: "").target = self
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: t("Report a Problem…", "Segnala un problema…"), action: #selector(reportProblem), keyEquivalent: "").target = self
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
        model?.overlayResting = false
        if !overlay.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            placeOverlay(on: screen)
            hover.inside = overlay.frame.contains(mouse)
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            // It fades in where it stays: the panel changes size with what it shows, and a rise would fight that.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? Motion.fast : Motion.slow; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 1
            }
        } else {
            // The island waiting at the top of another screen comes to the one under the pointer.
            if model?.settings.overlayStyle == .notch, let screen = pointerScreen, screen.frame != overlay.screen?.frame { placeOverlay(on: screen) }
            NSAnimationContext.runAnimationGroup { context in context.duration = Motion.fast; overlay.animator().alphaValue = 1 }
        }
    }

    private var pointerScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// At rest the island follows the pointer from screen to screen, so it is where you look; on
    /// a screen without a notch it shows as the pointer comes near the top.
    private var pointerWatch: Timer?
    private func followPointer(_ on: Bool) {
        guard on != (pointerWatch != nil) else { return }
        pointerWatch?.invalidate(); pointerWatch = nil
        hover.near = false
        guard on else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, let overlay = self.overlay, model.keepsDrop else { return }
                if model.overlayResting, !model.busy, !self.hover.inside, let screen = self.pointerScreen, screen.frame != overlay.screen?.frame { self.placeOverlay(on: screen) }
                let near = !self.hover.island.hasNotch && (overlay.screen.map { IslandGeometry.near(pointer: NSEvent.mouseLocation, screen: $0.frame, radius: Sizing.islandNear) } ?? false)
                if near != self.hover.near { self.hover.near = near }
            }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        pointerWatch = timer
    }

    /// Where the overlay goes on a screen: under the notch, at the top, for the notch style; above
    /// the Dock otherwise. The notch style draws on black in both themes and stands over the menu bar.
    private func placeOverlay(on screen: NSScreen?) {
        guard let overlay, let screen else { return }
        let notch = model?.settings.overlayStyle == .notch
        overlay.level = notch ? .statusBar : .floating
        overlay.hasShadow = !notch
        overlay.isMovableByWindowBackground = !notch
        overlay.contentView?.appearance = notch ? NSAppearance(named: .darkAqua) : nil
        hover.island = screen.island
        if notch { measureMenuRoom(on: screen) }
        if notch { overlay.setFrameOrigin(NSPoint(x: screen.frame.minX + screen.island.left(for: overlay.frame.width), y: screen.frame.maxY - overlay.frame.height)) }
        else { overlay.setFrameOrigin(NSPoint(x: (screen.visibleFrame.midX - overlay.frame.width / 2).rounded(), y: screen.visibleFrame.minY + 38)) }
    }
    /// The style changed, or the drop was turned on or off: the overlay goes where it now belongs.
    func placeOverlayAgain() {
        guard let model, let overlay else { return }
        followPointer(model.keepsDrop)
        let screen = overlay.screen ?? NSScreen.main
        if model.keepsDrop {
            if !overlay.isVisible { overlay.alphaValue = 1; overlay.orderFrontRegardless() }
            placeOverlay(on: screen)
            if !model.busy { model.overlayResting = true }
        } else if overlay.isVisible {
            placeOverlay(on: screen)
            if !model.busy { scheduleHide() }
        }
    }

    private func scheduleHide() {
        guard let overlay else { return }
        let generation = overlayGeneration
        hideTask = Task { [weak self, weak overlay] in
            // A failure stays long enough to read what to do next; a cancel, while it can be restored;
            // a message for its words and a moment of its symbol.
            let outcome = self?.model?.outcome
            let message = outcome == .empty || outcome == .hint || outcome == .learned || (outcome == .delivered && self?.model?.asSaid == true)
            let linger = self?.model?.pendingSuggestion != nil ? 10 : outcome == .failed ? Motion.lingerFailure : self?.model?.restorable != nil ? CancelledDictation.window - 2 : message ? Motion.message + 1 : Motion.linger
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            // Under the pointer, Restore and Show why stay until they are no longer on offer.
            while !Task.isCancelled, self?.hover.inside == true, self?.model?.restorable != nil || self?.model?.pendingSuggestion != nil || self?.model?.outcome == .failed { try? await Task.sleep(nanoseconds: 300_000_000) }
            // A question waiting in the overlay stays until it is answered or goes.
            while !Task.isCancelled, self?.model?.overlayHeld == true { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, let self, let overlay, generation == self.overlayGeneration else { return }
            // The notch style stays, with nothing but the notch.
            if self.model?.keepsDrop == true {
                self.model?.overlayResting = true; self.model?.pendingSuggestion = nil
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.base; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                overlay.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in
                guard generation == self.overlayGeneration else { return }
                overlay.orderOut(nil)
                // A suggestion not answered in time waits on the Dictionary page.
                self.model?.pendingSuggestion = nil
            } })
        }
    }

    /// Fits the panel around the overlay, keeping its centre and its bottom edge where they are;
    /// the notch style keeps its top edge, at the top of the screen.
    func fitOverlay(to size: CGSize) {
        guard let overlay, size.width >= 1, size.height >= 1 else { return }
        let frame = overlay.frame
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            let y = model?.settings.overlayStyle == .notch ? frame.maxY - size.height : frame.minY
            overlay.setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: y, width: size.width, height: size.height), display: true)
            overlay.invalidateShadow()
        }
    }

    /// How much of the menu bar left of the notch the app in front leaves free, read from its
    /// menus with Accessibility: the island's left wing never covers them.
    func measureMenuRoom(on given: NSScreen? = nil) {
        guard let screen = given ?? overlay?.screen ?? pointerScreen, let notch = screen.island.notch, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { hover.leftRoom = nil; return }
        let ends = Self.menuEnds(of: app.processIdentifier)
        guard !ends.isEmpty else { hover.leftRoom = nil; return }
        hover.leftRoom = CGFloat(MenuRoom.free(menuEnds: ends, notchLeft: Double(screen.island.center - notch.width / 2)))
    }
    /// The right edges of an app's menus, from the left edge of the screen showing them. Each
    /// screen lays the menus out from its own left edge, so these hold for every screen.
    static func menuEnds(of pid: pid_t) -> [Double] {
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?, children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success, let items = children as? [AXUIElement] else { return [] }
        // Accessibility measures from the top left of the main screen; AppKit from its bottom left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return items.compactMap { item in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success, let position, CFGetTypeID(position) == AXValueGetTypeID(),
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success, let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &extent)
            let home = NSScreen.screens.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX && abs($0.frame.maxY - (top - point.y)) < 60 }
            return Double(point.x + extent.width - (home?.frame.minX ?? 0))
        }
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

    func makeNotesWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // The title bar takes the paper's colour; the title stays, centred, as in any window.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSPalette.surfaceRaised
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .fullScreenNone]
        let content = NSHostingController(rootView: NotesPanelView().environmentObject(model).frame(limits: Self.notepadLimits))
        content.sizingOptions = [.minSize, .maxSize]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 780, height: 560))
        if !window.setFrameUsingName("VerbNotepad") { window.center() }
        window.setFrameAutosaveName("VerbNotepad")
        window.keep(within: Self.notepadLimits)
        notesDelegate.limits = Self.notepadLimits
        // A main window in the Dock keeps Verb in the Dock too.
        notesDelegate.closed = { [weak self] in if self?.window?.isVisible != true && self?.window?.isMiniaturized != true { NSApp.setActivationPolicy(.accessory) } }
        window.delegate = notesDelegate
        return window
    }

    @objc func showMainWindow() { NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func openSettings() { show(.settings) }
    func titleWindow(_ page: Page? = nil) {
        guard let model else { return }
        window?.title = "Verb · " + (page ?? model.page).title(model.lang)
    }
    @objc func goToPage(_ sender: NSMenuItem) { if Page.allCases.indices.contains(sender.tag) { show(Page.allCases[sender.tag]) } }
    /// A page asked for from a menu: it sets the welcome aside, to carry on at the next launch,
    /// and ends a tour.
    func show(_ page: Page) {
        guard let model else { return }
        if model.welcome != nil { model.welcome = nil }
        if model.tourStop != nil { model.endTour() }
        model.page = page; showMainWindow()
    }
    @objc func takeTour() { model?.startTour() }
    @objc func reportProblem() { model?.settingsTab = .general; show(.settings); model?.reporting = true }
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
    /// A size given from outside a drag, as by tiling, AppleScript or a saved frame, comes back
    /// within the limits too: a drag alone keeps to them by itself.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        window.keep(within: Self.mainLimits)
        measureWindowButtons()
    }

    /// Where macOS draws close, minimise and zoom in the main window, from its top left corner.
    func measureWindowButtons() {
        guard let window, let model, let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton) else { return }
        let first = close.convert(close.bounds, to: nil), last = zoom.convert(zoom.bounds, to: nil)
        let frame = CGRect(x: first.minX, y: window.frame.height - max(first.maxY, last.maxY), width: last.maxX - first.minX, height: max(first.height, last.height))
        guard frame.width > 0, model.windowButtons.frame != frame else { return }
        model.windowButtons = WindowButtons(frame: frame)
    }

    @objc func toggleSidebar(_ sender: Any?) { model?.settings.sidebarCollapsed.toggle() }
    func windowWillClose(_ notification: Notification) {
        // The Dock icon stays while the notepad is still open or waiting in the Dock.
        if notesWindow?.isVisible != true && notesWindow?.isMiniaturized != true { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Quitting mid-way stops work under way: a meeting, a dictation or a download asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let reason = model.quitWouldInterrupt(model.lang) else { return .terminateNow }
        let t = model.lang
        let alert = NSAlert()
        alert.messageText = reason.title; alert.informativeText = reason.detail
        alert.addButton(withTitle: reason.keep)
        alert.addButton(withTitle: t("Quit", "Esci"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

extension View {
    /// A window's smallest and largest sizes, for its hosting controller to hand to the window.
    func frame(limits: WindowLayout.Limits) -> some View {
        frame(minWidth: limits.min.width, maxWidth: limits.max.width, minHeight: limits.min.height, maxHeight: limits.max.height)
    }
}

extension NSWindow {
    /// Its size brought within the limits it has room for on its screen. The limits themselves
    /// are the view's: SwiftUI hands them to the window, and a drag keeps to them.
    func keep(within wanted: WindowLayout.Limits) {
        guard let screen = screen ?? NSScreen.main else { return }
        let limits = WindowLayout.limits(wanted, room: contentRect(forFrameRect: screen.visibleFrame).size)
        let size = contentRect(forFrameRect: frame).size
        let fitted = WindowLayout.fit(size, in: limits)
        if fitted != size { setContentSize(fitted) }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// The sidebar's command says what it will do.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleSidebar(_:)), let model else { return true }
        let t = model.lang
        item.title = model.settings.sidebarCollapsed ? t("Show Whole Sidebar", "Mostra tutta la barra laterale") : t("Show Only Icons in Sidebar", "Mostra solo le icone nella barra laterale")
        return model.welcome == nil
    }
}

/// Tells Verb when the notepad closes, to put Verb back in the menu bar alone.
final class NotesWindowDelegate: NSObject, NSWindowDelegate {
    var closed: () -> Void = {}
    var limits: WindowLayout.Limits?
    @MainActor func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let limits else { return }
        window.keep(within: limits)
    }
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
