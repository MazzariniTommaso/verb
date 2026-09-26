import AppKit
import SwiftUI
import VerbCore

// The notepad: thoughts dictated or typed, and the notes of meetings, as Markdown files in a
// folder. The same notepad is a page of the window and a panel that floats over other apps.

/// The Notes page of the window.
struct NotesPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader(rubric: t.count(model.notes.count, "note", "notes", "nota", "note"), title: t("Notes", "Note"),
                       detail: t("Dictate a thought, or record a meeting: the notes are Markdown files in a folder you choose.",
                                 "Detta un pensiero o registra una riunione: le note sono file Markdown in una cartella che scegli tu.")) {
                NotesActions()
            }
            MeetingBar()
            NotesBrowser(listWidth: 280)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
        }
        // The same top margin as the scrolling pages, so the title sits where theirs do.
        .padding(.horizontal, Space.page).padding(.top, Space.xxxl + Space.xs).padding(.bottom, Space.xxl)
        .frame(maxWidth: Sizing.contentMax + Space.page * 2, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.reloadNotes() }
    }
}

/// The notepad over other apps: the same notes, a little tighter.
struct NotesPanelView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Spacer()
                NotesActions(compact: true)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            MeetingBar().padding(.horizontal, Space.md).padding(.bottom, Space.sm)
            Hairline()
            NotesBrowser(listWidth: 210, minHeight: 260)
        }
        .background(Palette.surfaceRaised)
        .environment(\.lang, model.lang)
        .environment(\.locale, model.lang.locale)
        .onAppear { model.reloadNotes() }
    }
}

/// New note, and record a meeting.
private struct NotesActions: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var compact = false
    var body: some View {
        HStack(spacing: Space.sm) {
            if model.meeting == .idle {
                Button { model.startMeeting() } label: { Label(t("Record a meeting", "Registra una riunione"), systemImage: "person.2.wave.2") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: compact)).disabled(model.busy)
                    .help(t("Records your microphone and the sound of the Mac, then writes the notes here. Tell the others you are recording.",
                            "Registra il tuo microfono e l’audio del Mac, poi scrive qui le note. Avvisa gli altri che stai registrando."))
            }
            Button { model.newNote() } label: { Label(t("New note", "Nuova nota"), systemImage: "square.and.pencil") }
                .buttonStyle(VerbButtonStyle(kind: .primary, compact: compact))
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}

/// A meeting being recorded, with its time and Stop; or being written down.
struct MeetingBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        switch model.meeting {
        case .idle: EmptyView()
        case .recording(let started):
            HStack(spacing: Space.md) {
                Circle().fill(Palette.accent).frame(width: 9, height: 9)
                TimelineView(.periodic(from: started, by: 1)) { timeline in
                    Text(t("Recording the meeting · ", "Registro la riunione · ") + durationLabel(timeline.date.timeIntervalSince(started)))
                        .font(Typeface.text(TypeSize.body, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                }
                Spacer()
                Button { model.stopMeeting() } label: { Label(t("Stop and write the notes", "Termina e scrivi le note"), systemImage: "stop.fill") }
                    .buttonStyle(VerbButtonStyle(kind: .primary, compact: true))
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        case .writing(let text):
            HStack(spacing: Space.md) {
                InkDrops(width: 24, height: 14)
                Text(text).font(Typeface.display(TypeSize.body).italic()).foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }
}

/// The list of notes beside the open one.
struct NotesBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let listWidth: CGFloat
    /// The notepad is smaller than the page, and fits in its own minimum window.
    var minHeight: CGFloat = 380
    @State private var search = ""
    private var shown: [Note] {
        guard !search.isEmpty else { return model.notes }
        return model.notes.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(text: $search, prompt: t("Find in the notes", "Cerca nelle note"), clearLabel: t("Clear search", "Cancella la ricerca"))
                    .padding(Space.md)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { note in row(note) }
                    }
                    .padding(.horizontal, Space.sm).padding(.bottom, Space.md)
                }
            }
            .frame(width: listWidth)
            Rectangle().fill(Palette.borderSubtle).frame(width: 1)
            Group {
                if let url = model.openNote, let note = model.notes.first(where: { $0.url == url }) {
                    NoteEditorPane(note: note).id(url)
                } else {
                    VStack(spacing: Space.lg) {
                        EmptyState(symbol: "note.text", title: t("Your notepad", "Il tuo blocco note"),
                                   detail: t("Start a note and dictate into it with \(t.keys(model.settings.keyOptions.dictation)), as into any field.",
                                             "Inizia una nota e dettaci dentro con \(t.keys(model.settings.keyOptions.dictation)), come in qualsiasi campo."))
                        // The header already has the primary New note.
                        Button { model.newNote() } label: { Label(t("New note", "Nuova nota"), systemImage: "square.and.pencil") }.buttonStyle(VerbButtonStyle(kind: .secondary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: minHeight)
    }

    private func row(_ note: Note) -> some View {
        let selected = model.openNote == note.url
        return Button { model.openNote = note.url } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if note.isMeeting { Image(systemName: "person.2.wave.2").font(.system(size: 11)).foregroundStyle(Palette.textSecondary).accessibilityLabel(t("Meeting", "Riunione")) }
                    // A meeting's title ends with its time: it wraps rather than lose it.
                    Text(note.title ?? t("New note", "Nuova nota")).font(Typeface.display(TypeSize.callout)).foregroundStyle(Palette.textPrimary).lineLimit(note.isMeeting ? 2 : 1)
                }
                if !note.preview.isEmpty { Text(note.preview).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(2) }
                Text(t.relativeTime(note.modified)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.surfaceSelected : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(selected ? Palette.borderSubtle : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .contextMenu {
            Button(t("Show in Finder", "Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Button(t("Move to Trash", "Sposta nel Cestino"), role: .destructive) { model.trashNote(note.url) }
        }
    }
}

/// The open note: its tools, and the text.
private struct NoteEditorPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let note: Note
    @State private var text = ""
    @State private var saving: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            // With room, the tools say their names; in a narrow pane their icons are enough.
            ViewThatFits(in: .horizontal) {
                tools.labelStyle(.titleAndIcon)
                tools.labelStyle(.iconOnly)
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            Hairline()
            NoteTextView(text: $text)
        }
        .onAppear { text = note.text }
        .onChange(of: text) { _, value in
            guard value != note.text else { return }
            saving?.cancel()
            let url = note.url
            saving = Task { try? await Task.sleep(nanoseconds: 600_000_000); guard !Task.isCancelled else { return }; model.saveNote(url, text: value) }
        }
        .onDisappear { if text != note.text { model.saveNote(note.url, text: text) } }
    }
    private var tools: some View {
        HStack(spacing: Space.sm) {
            Button { model.handsFree = true; model.begin() } label: { Label(t("Dictate", "Detta"), systemImage: "mic") }
                .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.busy)
                .help(t("Dictates into the note where the cursor is. Space finishes.", "Detta nella nota dove si trova il cursore. Spazio termina."))
            Menu {
                ForEach(Array(model.library.transforms.enumerated()), id: \.element.id) { index, transform in
                    Button(transform.name) { model.transformNote(index) }
                }
            } label: { Label(t("Transform", "Trasforma"), systemImage: "wand.and.stars") }
                .menuStyle(.button).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).fixedSize().disabled(model.busy)
                .help(t("Rewrites the selection, or the whole note, with a transform.", "Riscrive la selezione, o tutta la nota, con una trasformazione."))
            Spacer()
            Button { model.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                .help(t("Copy the note", "Copia la nota")).accessibilityLabel(t("Copy the note", "Copia la nota"))
            Button { NSWorkspace.shared.activateFileViewerSelecting([note.url]) } label: { Image(systemName: "folder") }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                .help(t("Show in Finder", "Mostra nel Finder")).accessibilityLabel(t("Show in Finder", "Mostra nel Finder"))
            Button(role: .destructive) { model.trashNote(note.url) } label: { Image(systemName: "trash") }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                .help(t("Move to Trash", "Sposta nel Cestino")).accessibilityLabel(t("Move to Trash", "Sposta nel Cestino"))
        }
    }
}

/// The note's text, in the serif of Verb's words. When it has the cursor, Verb writes here.
/// The welcome's practice sheet is one too, larger, and takes the cursor as it appears.
struct NoteTextView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    @Binding var text: String
    var practice = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let view = FocusReportingTextView(frame: .zero)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        let coordinator = context.coordinator
        view.focused = { [weak coordinator] in guard let coordinator else { return }; coordinator.parent.model.noteEditor = coordinator }
        view.delegate = context.coordinator
        view.isRichText = false; view.allowsUndo = true; view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        let size: CGFloat = practice ? 17 : 15
        view.font = NSFont(descriptor: NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor, size: size)
        view.textColor = NSPalette.textPrimary
        view.insertionPointColor = NSPalette.accent
        view.textContainerInset = NSSize(width: 20, height: 18)
        view.defaultParagraphStyle = { let style = NSMutableParagraphStyle(); style.lineSpacing = practice ? 6 : 4; return style }()
        view.string = text
        view.focusWhenShown = practice
        view.setAccessibilityLabel(practice ? model.lang("Practice sheet", "Foglio di prova") : model.lang("Note", "Nota"))
        context.coordinator.view = view
        model.noteEditor = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let view = context.coordinator.view, view.string != text { view.string = text }
        if model.noteEditor == nil { model.noteEditor = context.coordinator }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.parent.model.noteEditor === coordinator { coordinator.parent.model.noteEditor = nil }
    }

    /// Tells Verb when it takes the cursor, so a dictation goes into this note.
    final class FocusReportingTextView: NSTextView {
        var focused: (() -> Void)?
        /// Takes the cursor as soon as it is in a window.
        var focusWhenShown = false
        override func becomeFirstResponder() -> Bool {
            let taken = super.becomeFirstResponder()
            if taken { focused?() }
            return taken
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusWhenShown else { return }
            DispatchQueue.main.async { [weak self] in guard let self, let window = self.window else { return }; window.makeFirstResponder(self) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NoteEditing {
        var parent: NoteTextView
        weak var view: NSTextView?
        init(_ parent: NoteTextView) { self.parent = parent }
        var isEditing: Bool {
            guard let view, let window = view.window else { return false }
            return window.isKeyWindow && window.firstResponder === view
        }
        var selectedText: String {
            guard let view else { return "" }
            return (view.string as NSString).substring(with: view.selectedRange())
        }
        var text: String { view?.string ?? "" }
        var isPractice: Bool { parent.practice }
        func insert(_ text: String) {
            guard let view else { return }
            view.insertText(text, replacementRange: view.selectedRange())
        }
        func selectAll() { view?.selectAll(nil) }
        func textDidChange(_ notification: Notification) { parent.text = view?.string ?? "" }
        func textDidBeginEditing(_ notification: Notification) { parent.model.noteEditor = self }
    }
}
