import SwiftUI
import VerbCore

extension KeyTarget {
    func title(_ t: Lang, transforms: [Transform]) -> String {
        switch self {
        case .dictation: return t("Dictation", "Dettatura")
        case .voiceEdit: return t("Edit or ask", "Modifica o chiedi")
        case .ask: return t("Ask a question", "Fai una domanda")
        case .copyLast: return t("Copy the last dictation", "Copia l’ultima dettatura")
        case .pasteLast: return t("Paste the last dictation", "Incolla l’ultima dettatura")
        case .notepad: return t("Notepad", "Blocco note")
        case .handsFree: return t("Hands-free with one press", "Mani libere con una pressione")
        case .transform(let id): return transforms.first { $0.id == id }?.name ?? t("Transform", "Trasformazione")
        }
    }
    func detail(_ t: Lang) -> String {
        switch self {
        case .dictation: return t("Hold and speak, let go to write.", "Tieni premuto e parla, rilascia per scrivere.")
        case .voiceEdit: return t("With text selected, say how to change it. With nothing selected, ask or say what to write.", "Con un testo selezionato, di’ come cambiarlo. Senza selezione, chiedi o di’ cosa scrivere.")
        case .ask: return t("Hold and ask: the answer comes in the overlay, and the next question follows on.", "Tieni premuto e chiedi: la risposta arriva nella capsula, e la domanda dopo prosegue.")
        case .copyLast: return t("Puts it on the clipboard.", "La mette negli appunti.")
        case .notepad: return t("Opens and closes the notepad over any app.", "Apre e chiude il blocco note sopra ogni app.")
        case .pasteLast: return t("Where the cursor is, even after a dictation with no field.", "Dove c’è il cursore, anche dopo una dettatura senza campo.")
        case .handsFree: return t("Optional: one press starts, another finishes.", "Facoltativo: una pressione avvia, un’altra termina.")
        case .transform: return t("Select some text and press the keys: the prompt rewrites it.", "Seleziona un testo e premi i tasti: il prompt lo riscrive.")
        }
    }
    /// The keys it starts with, for the actions.
    var standard: KeyBinding? { KeyBindings()[self] }
}

extension KeyBinding {
    /// The keys one by one, for keycaps: "⇧", "⌘", "C".
    var parts: [String] {
        let symbols = modifiers.symbols
        let key = keyCode == nil ? "" : String(label.dropFirst(symbols.count)).trimmingCharacters(in: .whitespaces)
        return symbols.split(separator: " ").map(String.init) + (key.isEmpty ? [] : [key])
    }
}

/// A key binding drawn as keycaps, or a quiet "no keys" when there are none.
struct KeyCaps: View {
    let binding: KeyBinding?
    var large = false
    @Environment(\.lang) private var t
    var body: some View {
        if let binding {
            HStack(spacing: large ? 6 : 3) {
                ForEach(Array(binding.parts.enumerated()), id: \.offset) { _, part in
                    if large {
                        Text(t.keys(part)).font(Typeface.text(TypeSize.title3, .medium)).foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Palette.borderStrong.opacity(0.6)))
                            .shadow(color: Palette.shadow.opacity(0.6), radius: 0, y: 2)
                    } else {
                        Keycap(text: t.keys(part))
                    }
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(t.spokenKeys(binding))
        } else {
            Text(t("No keys", "Nessun tasto")).font(Typeface.text(large ? TypeSize.title3 : TypeSize.caption, .medium).italic()).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// Which keys the capture window is changing.
struct KeyEditing: Identifiable {
    let target: KeyTarget
    var id: String { "\(target)" }
}

/// Keys that open the capture window when clicked.
struct KeyButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let target: KeyTarget
    @Binding var editing: KeyEditing?
    var minWidth: CGFloat = 120
    var body: some View {
        Button { editing = KeyEditing(target: target) } label: {
            KeyCaps(binding: model.binding(for: target))
                .padding(.horizontal, Space.md).frame(minWidth: minWidth, minHeight: 36)
                .background(Palette.fillHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .frame(minHeight: Sizing.controlMin).contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .help(t("Change the keys", "Cambia i tasti"))
        // Whose keys they are, and the keys in words, not symbols.
        .accessibilityLabel(t("Keys for \(target.title(t, transforms: model.library.transforms))", "Tasti per \(target.title(t, transforms: model.library.transforms))"))
        .accessibilityValue(t.spokenKeys(model.binding(for: target)))
        .accessibilityHint(t("Opens a window that listens for the new keys", "Apre una finestra che ascolta i nuovi tasti"))
    }
}

/// Hands-free by holding the dictation keys and tapping Space. It follows the dictation keys, so
/// it is shown here rather than chosen.
struct HandsFreeChordRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        SettingRow(title: t("Hands-free dictation", "Dettatura a mani libere"),
                   detail: t("Hold the dictation keys and tap Space. Space finishes, Escape cancels.",
                             "Tieni i tasti della dettatura e tocca Spazio. Spazio termina, Esc annulla.")) {
            HStack(spacing: 3) {
                if let keys = model.settings.keyOptions.dictation {
                    KeyCaps(binding: keys)
                    Text("+").font(Typeface.text(TypeSize.caption, .medium)).foregroundStyle(Palette.textSecondary)
                    Keycap(text: t("Space", "Spazio"))
                } else {
                    KeyCaps(binding: nil)
                }
            }
            .padding(.horizontal, Space.md).frame(minWidth: 120, minHeight: 36)
            .frame(minHeight: Sizing.controlMin)
            .help(t("It follows the Dictation keys.", "Segue i tasti della Dettatura."))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t("Keys for hands-free dictation", "Tasti per la dettatura a mani libere"))
            .accessibilityValue(model.settings.keyOptions.dictation.map { t.spokenKeys($0) + ", " + t("then Space", "poi Spazio") } ?? t("No keys", "Nessun tasto"))
        }
    }
}

/// One action in Settings → Keyboard: what it does, and its keys.
struct KeyBindingRow: View {
    @Environment(\.lang) private var t
    let target: KeyTarget
    @Binding var editing: KeyEditing?
    var body: some View {
        SettingRow(title: target.title(t, transforms: []), detail: target.detail(t)) { KeyButton(target: target, editing: $editing) }
    }
}

extension AppModel {
    /// The keys of an action or a transform.
    func binding(for target: KeyTarget) -> KeyBinding? {
        if case .transform(let id) = target { return library.transforms.first { $0.id == id }?.keys }
        return settings.keyOptions[target]
    }
    /// Gives the keys to `target`, or takes its keys away. Whoever had them loses them.
    func assign(_ binding: KeyBinding?, to target: KeyTarget) {
        var keys = settings.keyOptions, transforms = library.transforms
        KeyBindings.assign(binding, to: target, keys: &keys, transforms: &transforms)
        if transforms != library.transforms { library.transforms = transforms }
        if keys != settings.keyOptions { settings.keyOptions = keys }
    }
}

/// "Press the keys": the window where keys are chosen, as in games. It listens to the
/// keyboard, shows the keys as they are pressed, and keeps the last ones until they are used.
/// Keys another command had move here, and that command is left without keys.
struct KeyCaptureSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    let target: KeyTarget
    @State private var held: KeyModifiers = []
    @State private var captured: KeyBinding?
    @State private var listening = true
    /// `captured` starts filled in only for snapshots.
    init(target: KeyTarget, captured: KeyBinding? = nil) { self.target = target; _captured = State(initialValue: captured); _listening = State(initialValue: captured == nil) }
    var body: some View {
        let problem = captured.flatMap(problemText)
        let owner = captured.flatMap { KeyBindings.owner(of: $0, keys: model.settings.keyOptions, transforms: model.library.transforms) }.flatMap { $0 == target ? nil : $0 }
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(t("Keys for “\(target.title(t, transforms: model.library.transforms))”", "Tasti per “\(target.title(t, transforms: model.library.transforms))”"))
                .font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary).lineLimit(2).accessibilityAddTraits(.isHeader)
            Text(target.hold
                 ? t("Press the keys you want to use. fn on its own works, as do two or more modifiers together (⌃ ⌥) or a key with ⌃, ⌥ or ⌘. Escape cancels.",
                     "Premi i tasti che vuoi usare. Va bene fn da solo, due o più modificatori insieme (⌃ ⌥) oppure un tasto con ⌃, ⌥ o ⌘. Esc annulla.")
                 : t("Press the combination you want to use: a key with ⌃, ⌥ or ⌘, or a function key. Escape cancels.",
                     "Premi la combinazione che vuoi usare: un tasto con ⌃, ⌥ o ⌘, oppure un tasto funzione. Esc annulla."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Palette.surfaceSunken)
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle)
                if !held.isEmpty {
                    KeyCaps(binding: KeyBinding(modifiers: held, label: held.symbols), large: true).opacity(0.8)
                } else if let captured {
                    KeyCaps(binding: captured, large: true)
                } else {
                    Text(t("Listening…", "In ascolto…")).font(Typeface.display(TypeSize.title3).italic()).foregroundStyle(Palette.textSecondary)
                }
                KeyCaptureField(listening: listening, onHeld: { held = $0 }, onCapture: { binding in
                    captured = binding; held = []; listening = false
                    // What was pressed, and what it means, for VoiceOver.
                    Announcer.say(t.spokenKeys(binding) + ". " + (problemText(binding) ?? caution(binding) ?? t("Return uses them.", "Invio li usa.")))
                }, onCancel: { dismiss() })
                    .frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
            }
            .frame(height: 120)
            // The keys caught stay until they are used; this listens again.
            .overlay(alignment: .bottomTrailing) {
                if !listening {
                    Button(t("Press other keys", "Premi altri tasti")) { captured = nil; listening = true }
                        .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)).padding(.trailing, Space.sm)
                }
            }
            if let problem {
                StatusLabel(text: problem, symbol: "exclamationmark.triangle", tone: .warning)
            } else if let owner {
                let name = owner.title(t, transforms: model.library.transforms)
                StatusLabel(text: t("These keys are set for “\(name)”: they will move here, and “\(name)” will have no keys.",
                                    "Questi tasti sono di “\(name)”: passeranno qui e “\(name)” resterà senza tasti."), symbol: "arrow.left.arrow.right", tone: .warning)
            } else if let captured, let caution = caution(captured) {
                StatusLabel(text: caution, symbol: "exclamationmark.triangle", tone: .warning)
            } else if captured != nil {
                StatusLabel(text: t("Ready to use.", "Pronti da usare."), symbol: "checkmark.circle", tone: .success)
            }
            HStack(spacing: Space.sm) {
                if model.binding(for: target) != nil {
                    Button(t("Remove the keys", "Togli i tasti")) { model.assign(nil, to: target); dismiss() }.buttonStyle(VerbButtonStyle(kind: .secondary))
                }
                if let standard = target.standard, model.binding(for: target) != standard {
                    Button(t("Use \(t.keys(standard.label))", "Usa \(t.keys(standard.label))")) { captured = standard }.buttonStyle(VerbButtonStyle(kind: .quiet))
                }
                Spacer()
                Button(t("Cancel", "Annulla")) { dismiss() }.buttonStyle(VerbButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Button(t("Use these keys", "Usa questi tasti")) {
                    guard let captured else { return }
                    model.assign(captured, to: target); dismiss()
                }
                .buttonStyle(VerbButtonStyle(kind: .primary)).disabled(captured == nil || problem != nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 520)
        .background(Palette.surfacePage)
        // While this window listens, the keys it hears must not also act.
        .onAppear { model.hotkeys.suspended = true }
        .onDisappear { model.hotkeys.suspended = false }
    }

    /// What the keys would take from someone else, when they can be used all the same.
    private func caution(_ binding: KeyBinding) -> String? {
        if binding.usesVoiceOverKeys, NSWorkspace.shared.isVoiceOverEnabled {
            return t("VoiceOver uses ⌃ ⌥ for its commands: these keys can get in its way.", "VoiceOver usa ⌃ ⌥ per i suoi comandi: questi tasti possono intralciarlo.")
        }
        let apps = binding.knownUsers
        guard !apps.isEmpty else { return nil }
        let names = apps.formatted(.list(type: .and).locale(t.locale))
        return t("\(names) also use these keys. Verb takes them in every app.", "Anche \(names) usano questi tasti. Verb li prende in tutte le app.")
    }
    /// Why the keys can't be used at all, in words; nil when they can.
    private func problemText(_ binding: KeyBinding) -> String? {
        if binding.usesVoiceOverKeys, binding.isModifierOnly, NSWorkspace.shared.isVoiceOverEnabled {
            return t("VoiceOver holds ⌃ ⌥ for every command, so Verb leaves them to it while it runs. Choose other keys.", "VoiceOver tiene premuti ⌃ ⌥ per ogni comando, quindi Verb li lascia a VoiceOver finché è attivo. Scegli altri tasti.")
        }
        if Hotkeys.systemUses(binding) {
            return t("macOS uses these keys for one of its shortcuts. Choose others, or turn that one off in Keyboard Shortcuts.", "macOS usa questi tasti per una sua scorciatoia. Scegline altri, o disattiva quella in Abbreviazioni da tastiera.")
        }
        switch binding.problem(hold: target.hold) {
        case nil: return nil
        case .needsModifier: return t("Add ⌃, ⌥ or ⌘: on its own that key is for typing. F1 to F20 work on their own.", "Aggiungi ⌃, ⌥ o ⌘: da solo quel tasto serve per scrivere. Da F1 a F20 vanno bene anche da soli.")
        case .singleModifier: return t("One modifier alone is part of typing and of many shortcuts. Use fn alone, or at least two modifiers together (⌃ ⌥).", "Un solo modificatore serve già per scrivere e per molte scorciatoie. Usa fn da solo, o almeno due modificatori insieme (⌃ ⌥).")
        case .functionWithKey: return t("fn works only on its own. For a combination, use ⌃, ⌥ or ⌘.", "fn funziona solo da solo. Per una combinazione usa ⌃, ⌥ o ⌘.")
        case .reserved: return t("macOS or every app already uses these keys.", "Questi tasti li usa già macOS o ogni app.")
        case .needsKey: return t("This is pressed once: it needs a key with the modifiers.", "Questo si preme una volta: serve un tasto insieme ai modificatori.")
        case .spaceIsHandsFree: return t("Space turns a held dictation hands-free, so it can’t hold one. Choose another key.", "Spazio passa la dettatura a mani libere, quindi non può tenerla premuta. Scegli un altro tasto.")
        }
    }
}
