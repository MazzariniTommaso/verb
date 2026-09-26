import AppKit
import SwiftUI
import VerbCore

/// The status item: the V-swallow in the menu bar, and the menu it opens. The menu is rebuilt
/// every time it opens, so it always reflects the current state and language.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var showWindow: () -> Void = {}
    var showPage: (Page) -> Void = { _ in }
    var showNotepad: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let t = model.lang
        let meeting: Bool = { if case .recording = model.meeting { return true }; return false }()
        let state: MenuBarIcon.State = model.phase == .recording || meeting ? .recording : (model.busy ? .working : .idle)
        let description = model.busy ? model.phaseTitle(t) : t("Verb dictation", "Dettatura Verb")
        item.button?.image = MenuBarIcon.image(state, description: description)
        item.button?.toolTip = model.busy ? description : "Verb · " + model.startHint(t)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if model.settings.cleanupProvider == .harness, model.settings.allowRemoteProcessing, !model.harnessLoading, !model.busy, Date().timeIntervalSince(model.harnessCatalog?.fetchedAt ?? .distantPast) > 60 { model.refreshHarness() }
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        let t = model.lang
        menu.removeAllItems()
        let header = NSMenuItem(); header.isEnabled = false
        let idle = model.voiceListening ? t("Listening", "In ascolto") : t("Ready", "Pronto")
        let view = NSHostingView(rootView: MenuHeader(title: model.busy ? model.phaseTitle(t) : idle, hint: model.startHint(t), live: model.phase == .recording, liveLabel: t("Recording", "In registrazione")))
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 52)
        header.view = view
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, model.phase == .recording ? t("Finish dictation", "Termina la dettatura") : t("Start hands-free dictation", "Avvia la dettatura a mani libere"), symbol: model.phase == .recording ? "stop.circle" : "mic", #selector(toggle))
        if model.busy { add(menu, t("Cancel", "Annulla"), symbol: "xmark.circle", #selector(cancel)) }
        if model.restorable != nil, !model.busy { add(menu, t("Restore the cancelled dictation", "Ripristina la dettatura annullata"), symbol: "arrow.uturn.backward", #selector(restoreCancelled)) }
        add(menu, t("Import audio…", "Importa audio…"), symbol: "square.and.arrow.down", #selector(importAudio)).isEnabled = !model.busy
        let notepad = add(menu, t("Notepad", "Blocco note"), symbol: "note.text", #selector(openNotepad)); Self.show(model.settings.keyOptions.notepad, on: notepad)
        switch model.meeting {
        case .idle: add(menu, t("Record a meeting", "Registra una riunione"), symbol: "person.2.wave.2", #selector(startMeeting)).isEnabled = !model.busy
        case .recording: add(menu, t("Stop the meeting and write the notes", "Termina la riunione e scrivi le note"), symbol: "stop.circle", #selector(stopMeeting))
        case .writing(let text): add(menu, text, symbol: "hourglass", nil).isEnabled = false
        }
        let copyRow = add(menu, t("Copy last dictation", "Copia l’ultima dettatura"), symbol: "doc.on.doc", #selector(copyLast))
        copyRow.isEnabled = !model.latestText.isEmpty; Self.show(model.settings.keyOptions.copyLast, on: copyRow)
        if model.inserter.hasPreviousClipboard { add(menu, t("Restore previous clipboard", "Ripristina gli appunti precedenti"), symbol: "arrow.uturn.backward", #selector(restoreClipboard)) }
        let name = model.settings.voiceOptions.spokenName
        let listen = add(menu, t("Listen for “Hey \(name)”", "Ascolta “Ehi \(name)”"), symbol: "waveform", #selector(toggleListening))
        listen.state = model.settings.voiceOptions.wakeWord ? .on : .off
        listen.isEnabled = model.speechInstalled
        if !model.speechInstalled { listen.toolTip = t("Needs the speech model on this Mac", "Serve il modello vocale su questo Mac") }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: t("Writing", "Scrittura")))
        addProviders(to: menu, t)

        if !model.library.transforms.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: t("Transforms", "Trasformazioni")))
            // Nine in the menu itself, any others in a submenu, so the menu stays short.
            for (index, transform) in model.library.transforms.enumerated() where index < 9 {
                let row = add(menu, transform.name, symbol: nil, #selector(transform(_:)))
                row.tag = index; row.isEnabled = !model.busy; Self.show(transform.keys, on: row)
            }
            if model.library.transforms.count > 9 {
                let more = add(menu, t("More Transforms", "Altre trasformazioni"), symbol: nil, nil)
                let submenu = NSMenu(); submenu.autoenablesItems = false
                for (index, transform) in model.library.transforms.enumerated() where index >= 9 {
                    let row = add(submenu, transform.name, symbol: nil, #selector(transform(_:)))
                    row.tag = index; row.isEnabled = !model.busy; Self.show(transform.keys, on: row)
                }
                more.submenu = submenu
            }
        }

        menu.addItem(.separator())
        let appearance = add(menu, t("Appearance", "Aspetto"), symbol: "circle.lefthalf.filled", nil)
        appearance.submenu = choices(Appearance.allCases, current: model.settings.interfaceOptions.appearance, title: { $0.title(t) }, action: #selector(chooseAppearance(_:)))
        let overlayStyle = add(menu, t("Overlay", "Capsula"), symbol: "capsule", nil)
        overlayStyle.submenu = choices(OverlayStyle.allCases, current: model.settings.overlayStyle, title: { $0.title(t) }, action: #selector(chooseOverlay(_:)))
        let language = add(menu, t("Language", "Lingua"), symbol: "globe", nil)
        language.submenu = choices(InterfaceLanguage.allCases, current: model.settings.interfaceOptions.language, title: { $0.nativeName }, action: #selector(chooseLanguage(_:)))

        menu.addItem(.separator())
        add(menu, t("Open Verb", "Apri Verb"), symbol: "macwindow", #selector(openWindow))
        add(menu, t("Settings…", "Impostazioni…"), symbol: "gearshape", #selector(openSettings)).keyEquivalent = ","
        menu.addItem(.separator())
        add(menu, t("Quit Verb", "Esci da Verb"), symbol: "power", #selector(quit)).keyEquivalent = "q"
    }

    private func addProviders(to menu: NSMenu, _ t: Lang) {
        let providers = NSMenu(); providers.autoenablesItems = false
        func entry(_ title: String, value: String, selected: Bool) {
            let row = providers.addItem(withTitle: title, action: #selector(selectWritingProvider(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = value; row.state = selected ? .on : .off; row.isEnabled = !model.busy && !model.harnessTesting
        }
        let settings = model.settings
        entry(t("On this Mac · Ollama", "Su questo Mac · Ollama"), value: "local", selected: settings.cleanupProvider == .local)
        for provider in HarnessProvider.allCases { entry(provider.title, value: provider.rawValue, selected: settings.cleanupProvider == .harness && settings.harnessOptions.provider == provider) }
        providers.addItem(.separator())
        entry(CleanupProvider.endpoint.title(t), value: "endpoint", selected: settings.cleanupProvider == .endpoint)
        entry(CleanupProvider.off.title(t), value: "off", selected: settings.cleanupProvider == .off)
        let current: String
        switch settings.cleanupProvider {
        case .local: current = t("On this Mac", "Su questo Mac")
        case .harness: current = settings.harnessOptions.provider.title
        case .endpoint: current = CleanupProvider.endpoint.title(t)
        case .off: current = t("None", "Nessuno")
        }
        add(menu, t("Writing model · ", "Modello di scrittura · ") + current, symbol: "pencil.line", nil).submenu = providers

        guard settings.cleanupProvider == .harness else { return }
        let models = NSMenu(); models.autoenablesItems = false
        for value in model.harnessCatalog?.models ?? [] {
            let row = models.addItem(withTitle: value.name, action: #selector(selectWritingModel(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = value.id; row.state = value.id == settings.harnessOptions.model ? .on : .off; row.toolTip = value.detail
            row.isEnabled = !model.busy && !model.harnessTesting
        }
        if models.items.isEmpty { let row = models.addItem(withTitle: t("Connect in Models…", "Collega in Modelli…"), action: #selector(openModels), keyEquivalent: ""); row.target = self }
        models.addItem(.separator())
        let refresh = models.addItem(withTitle: model.harnessLoading ? t("Refreshing…", "Aggiornamento…") : t("Refresh available models", "Aggiorna i modelli disponibili"), action: #selector(refreshModels), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = !model.harnessLoading
        let name = model.harnessCatalog?.models.first(where: { $0.id == settings.harnessOptions.model })?.name ?? t("Choose…", "Scegli…")
        add(menu, t("Model · ", "Modello · ") + name, symbol: "square.stack.3d.up", nil).submenu = models
        if !settings.allowRemoteProcessing { add(menu, t("Remote processing is off · set up…", "Elaborazione remota spenta · configura…"), symbol: "exclamationmark.triangle", #selector(openModels)) }
    }

    /// Writes keys beside a menu item when they end in a letter or a digit; the menu can't draw others.
    static func show(_ binding: KeyBinding?, on row: NSMenuItem) {
        guard let binding, let key = binding.parts.last, key.count == 1, binding.keyCode != nil else { return }
        row.keyEquivalent = key.lowercased()
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.control) { flags.insert(.control) }
        if binding.modifiers.contains(.option) { flags.insert(.option) }
        if binding.modifiers.contains(.shift) { flags.insert(.shift) }
        if binding.modifiers.contains(.command) { flags.insert(.command) }
        row.keyEquivalentModifierMask = flags
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, symbol: String?, _ action: Selector?) -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        row.target = action == nil ? nil : self
        if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return row
    }

    private func choices<Value: RawRepresentable>(_ values: [Value], current: Value, title: (Value) -> String, action: Selector) -> NSMenu where Value.RawValue == String {
        let submenu = NSMenu(); submenu.autoenablesItems = false
        for value in values {
            let row = submenu.addItem(withTitle: title(value), action: action, keyEquivalent: "")
            row.target = self; row.representedObject = value.rawValue; row.state = value.rawValue == current.rawValue ? .on : .off
        }
        return submenu
    }

    @objc private func restoreCancelled() { model.restoreCancelled() }
    @objc private func openNotepad() { showNotepad() }
    @objc private func startMeeting() { model.startMeeting() }
    @objc private func stopMeeting() { model.stopMeeting() }
    @objc private func toggle() { if model.phase == .recording { model.finish() } else { model.toggle() } }
    @objc private func cancel() { model.cancel() }
    /// Opens History first, so the panel comes up in front and the result lands on the page you are looking at.
    @objc private func importAudio() { showPage(.history); model.importAudio() }
    @objc private func copyLast() { if !model.latestText.isEmpty { model.copy(model.latestText) } }
    @objc private func restoreClipboard() { model.inserter.restoreClipboard() }
    @objc private func toggleListening() { model.settings.voiceOptions.wakeWord.toggle() }
    @objc private func transform(_ sender: NSMenuItem) { model.applyTransform(sender.tag) }
    @objc private func openWindow() { showWindow() }
    @objc private func openSettings() { showPage(.settings) }
    @objc private func openModels() { showPage(.models) }
    @objc private func refreshModels() { model.refreshHarness() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Appearance(rawValue: raw) else { return }
        model.settings.interfaceOptions.appearance = value
    }
    @objc private func chooseOverlay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = OverlayStyle(rawValue: raw) else { return }
        model.settings.overlayStyle = value
    }
    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = InterfaceLanguage(rawValue: raw) else { return }
        model.settings.interfaceOptions.language = value
    }
    @objc private func selectWritingProvider(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, !model.busy else { return }
        if let provider = HarnessProvider(rawValue: value) {
            model.selectHarness(provider)
            if !model.settings.allowRemoteProcessing || model.settings.harnessOptions.model.isEmpty { showPage(.models) }
        } else if let provider = CleanupProvider(rawValue: value) { model.settings.cleanupProvider = provider }
    }
    @objc private func selectWritingModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, !model.busy else { return }
        model.settings.harnessOptions.model = value
    }
}

/// The top of the menu: the mark, the state, and how to start.
struct MenuHeader: View {
    let title: String
    let hint: String
    let live: Bool
    var liveLabel = "Recording"
    var body: some View {
        HStack(spacing: Space.md) {
            VerbMark(small: true).fill(Palette.accent).frame(width: 24, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs + 2) {
                    Text("Verb").font(Typeface.display(TypeSize.callout, .semibold)).foregroundStyle(.primary)
                    Text("·").foregroundStyle(.secondary)
                    Text(title).font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(hint).font(Typeface.text(TypeSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if live { Circle().fill(Palette.accent).frame(width: 8, height: 8).accessibilityLabel(liveLabel) }
        }
        .padding(.horizontal, Space.base)
        .frame(width: 280, height: 52, alignment: .leading)
    }
}
