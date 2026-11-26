import AppKit
import SwiftUI
import VerbCore

// The notepad: thoughts dictated or typed, and the notes of meetings, as Markdown files in a
// folder. The same notepad is a page of the window and a panel that floats over other apps.

/// The Notes page of the window.
struct NotesPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.pageLayout) private var layout
    var body: some View {
        // The notes take the room the window has. When it is too short for them beside a meeting's
        // own tools, the page scrolls instead, the notes at their usual height.
        ViewThatFits(in: .vertical) {
            column(browser: nil)
            ScrollView { column(browser: 380) }
        }
        .onAppear { model.reloadNotes() }
    }

    private func column(browser height: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader(rubric: t.count(model.notes.count, "note", "notes", "nota", "note"), title: t("Notes", "Note"),
                       detail: t("Dictate a thought, or record a meeting: the notes are Markdown files in a folder you choose.",
                                 "Detta un pensiero o registra una riunione: le note sono file Markdown in una cartella che scegli tu.")) {
                NotesActions()
            }
            MeetingBar()
            FailedMeetings()
            NotesBrowser(list: (0.28, 240, 320), minHeight: 260, foldBelow: Sizing.notepadListBelow)
                .frame(height: height)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
        }
        // The same margins as the scrolling pages, so the title sits where theirs do. This page
        // is where you write: it takes the whole room, and the note's lines keep their measure.
        .padding(.horizontal, layout.margin).padding(.top, Sizing.pageTop).padding(.bottom, Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The notepad over other apps: the same notes, a little tighter.
struct NotesPanelView: View {
    @EnvironmentObject var model: AppModel
    /// Folded, it opens on the list rather than the note.
    var showingList = false
    var body: some View {
        VStack(spacing: 0) {
            // One bar: New note and Record a meeting sit with the note's own tools.
            MeetingBar(compact: true).padding(.horizontal, Space.md).padding(.vertical, model.meeting == .idle ? 0 : Space.sm)
            if model.meeting != .idle { Hairline() }
            NotesBrowser(list: (0.3, 200, 280), minHeight: 260, panel: true, foldBelow: Sizing.notepadListBelow, showingList: showingList)
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
    /// In the notepad, where room is short.
    var compact = false
    var body: some View {
        switch model.meeting {
        case .idle: EmptyView()
        case .recording(let started):
            VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Circle().fill(Palette.accent).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: started, by: 1)) { timeline in
                        Text(t("Recording the meeting · ", "Registro la riunione · ") + durationLabel(timeline.date.timeIntervalSince(started)))
                            .font(Typeface.text(TypeSize.body, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    }
                    Text(t("Let the others know you are recording.", "Avvisa gli altri che stai registrando.")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button { model.stopMeeting() } label: { Label(t("Stop and write the notes", "Termina e scrivi le note"), systemImage: "stop.fill") }
                    .buttonStyle(VerbButtonStyle(kind: .primary, compact: true))
            }
            MeetingNotesField(compact: compact)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        case .writing(let text):
            HStack(spacing: Space.md) {
                InkDrops(width: 24, height: 14)
                Text(text + (model.meetingProgress.map { " · " + $0.formatted(.percent.precision(.fractionLength(0)).locale(t.locale)) } ?? ""))
                    .font(Typeface.display(TypeSize.body).italic()).monospacedDigit().foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }
}

/// Meetings whose notes couldn't be written: their recordings wait here until you retry or delete them.
struct FailedMeetings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var deleting: FailedMeeting?
    var body: some View {
        if !model.failedMeetings.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(model.failedMeetings) { failed in
                    HStack(spacing: Space.md) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.warning).accessibilityHidden(true)
                        Text(t("Meeting of \(failed.started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(t.locale))) · not written down",
                               "Riunione del \(failed.started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(t.locale))) · non scritta"))
                            .font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Button(t("Delete", "Elimina"), role: .destructive) { deleting = failed }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                        Button(t("Show recordings", "Mostra le registrazioni")) { NSWorkspace.shared.activateFileViewerSelecting([failed.folder]) }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                        Button(t("Retry", "Riprova")) { model.retryMeeting(failed.folder) }.buttonStyle(VerbButtonStyle(kind: .primary, compact: true)).disabled(model.meeting != .idle)
                    }
                }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Palette.warningTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.warning.opacity(0.35)))
            .confirmationDialog(t("Delete this meeting’s recordings?", "Eliminare le registrazioni di questa riunione?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { failed in
                Button(t("Delete", "Elimina"), role: .destructive) { model.deleteMeeting(failed.folder) }
                Button(t("Cancel", "Annulla"), role: .cancel) {}
            } message: { _ in Text(t("Its notes were never written, and they can’t be once the recordings are gone.", "Le note non sono mai state scritte, e senza registrazioni non si potrà più.")) }
        }
    }
}

/// The list of notes beside the open one. Narrower than `foldBelow`, as in a small notepad, it
/// shows one at a time: the list, or the note with a way back to the list.
struct NotesBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    /// The list's share of the width, and its narrowest and widest.
    let list: (share: CGFloat, least: CGFloat, most: CGFloat)
    /// The notepad is smaller than the page, and fits in its own minimum window.
    var minHeight: CGFloat = 380
    /// In the notepad, the note's tools also make notes and record meetings: there is no page header.
    var panel = false
    var foldBelow: CGFloat = 0
    @State private var search = ""
    @State private var showingList: Bool
    init(list: (share: CGFloat, least: CGFloat, most: CGFloat), minHeight: CGFloat = 380, panel: Bool = false, foldBelow: CGFloat = 0, showingList: Bool = false) {
        self.list = list; self.minHeight = minHeight; self.panel = panel; self.foldBelow = foldBelow
        _showingList = State(initialValue: showingList)
    }
    private var shown: [Note] {
        guard !search.isEmpty else { return model.notes }
        return model.notes.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    /// Folded, the list stands alone while it is asked for or no note is open.
    private func listAlone(_ folded: Bool) -> Bool { folded && !model.notes.isEmpty && (showingList || model.openNote == nil) }
    var body: some View {
        // Read in the same pass as the layout, so a narrow notepad never needs the room of two panes.
        GeometryReader { proxy in
            let folded = proxy.size.width < foldBelow
            HStack(spacing: 0) {
                if !folded {
                    notes(folded).frame(width: PageLayout.pane(of: proxy.size.width, share: list.share, least: list.least, most: list.most))
                    Rectangle().fill(Palette.borderSubtle).frame(width: 1)
                    detail(folded)
                } else if listAlone(folded) {
                    notes(folded).frame(maxWidth: .infinity)
                } else {
                    detail(folded)
                }
            }
        }
        .frame(minHeight: minHeight)
    }

    private func notes(_ folded: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                SearchField(text: $search, prompt: t("Find in the notes", "Cerca nelle note"), clearLabel: t("Clear search", "Cancella la ricerca"), sunken: true)
                // Alone in a small notepad, the list makes notes itself.
                if listAlone(folded) && panel { IconButton(symbol: "square.and.pencil", label: t("New note", "Nuova nota")) { showingList = false; model.newNote() } }
            }
            .padding(Space.md)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { note in row(note) }
                    if shown.isEmpty, !search.isEmpty {
                        Text(t("No note contains “\(search)”.", "Nessuna nota contiene “\(search)”."))
                            .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Space.sm).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.sm).padding(.bottom, Space.md)
            }
        }
    }

    private func detail(_ folded: Bool) -> some View {
        Group {
            if let url = model.openNote, let note = model.notes.first(where: { $0.url == url }) {
                NoteEditorPane(note: note, panel: panel, back: folded ? { showingList = true } : nil).id(url)
            } else if model.notesFolderUnreachable {
                VStack(spacing: Space.lg) {
                    EmptyState(symbol: "folder.badge.questionmark", title: t("Can’t reach the notes folder", "Non raggiungo la cartella delle note"),
                               detail: t("\(model.notesFolder.path) isn’t there now: iCloud may be offline, or the disk unplugged. The notes come back when it is.",
                                         "\(model.notesFolder.path) ora non c’è: forse iCloud è offline o il disco è scollegato. Le note tornano quando c’è."))
                    HStack(spacing: Space.sm) {
                        Button(t("Try again", "Riprova")) { model.reloadNotes() }.buttonStyle(VerbButtonStyle(kind: .secondary))
                        Button(t("Choose another folder…", "Scegli un’altra cartella…")) { model.chooseNotesFolder() }.buttonStyle(VerbButtonStyle(kind: .secondary))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: Space.lg) {
                    EmptyState(symbol: "note.text", title: t("Your notepad", "Il tuo blocco note"),
                               detail: model.settings.keyOptions.dictation == nil ? t("Start a note and dictate into it, as into any field.", "Inizia una nota e dettaci dentro, come in qualsiasi campo.")
                                    : t("Start a note and dictate into it with \(t.keys(model.settings.keyOptions.dictation)), as into any field.",
                                        "Inizia una nota e dettaci dentro con \(t.keys(model.settings.keyOptions.dictation)), come in qualsiasi campo."))
                    // The header already has the primary New note.
                    Button { model.newNote() } label: { Label(t("New note", "Nuova nota"), systemImage: "square.and.pencil") }.buttonStyle(VerbButtonStyle(kind: .secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ note: Note) -> some View {
        let selected = model.openNote == note.url
        return Button { model.openNote = note.url; showingList = false } label: {
            VStack(alignment: .leading, spacing: 3) {
                // A meeting's title ends with its time: it wraps rather than lose it.
                Text(note.title ?? t("New note", "Nuova nota")).font(Typeface.display(TypeSize.callout, selected ? .semibold : .regular)).foregroundStyle(Palette.textPrimary).lineLimit(note.isMeeting ? 2 : 1)
                if !note.preview.isEmpty { Text(note.preview).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(2) }
                // Every title starts at the same edge: a meeting says so beside its date.
                HStack(spacing: Space.xs) {
                    if note.isMeeting { Image(systemName: "person.2.wave.2").font(.system(size: 10)).foregroundStyle(Palette.textSecondary).accessibilityLabel(t("Meeting", "Riunione")) }
                    Text(t.relativeTime(note.modified)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.fillHover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            // The open note has a bar at its edge in the colour of on, besides its fill.
            .overlay(alignment: .leading) { if selected { Capsule().fill(Palette.controlOn).frame(width: 3).padding(.vertical, Space.sm) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
    var panel = false
    /// In a folded notepad, the way back to the list.
    var back: (() -> Void)? = nil
    @State private var text = ""
    @State private var saving: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            // With room, the tools say their names; in a narrow pane their icons are enough.
            ViewThatFits(in: .horizontal) {
                tools().labelStyle(.titleAndIcon)
                tools().labelStyle(.iconOnly)
                // Narrower still, what is done with the file waits in one menu.
                tools(more: true).labelStyle(.iconOnly)
            }
            // The tools start where the text does, 20 pt in.
            .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
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
    private func tools(more: Bool = false) -> some View {
        HStack(spacing: Space.sm) {
            if let back {
                Button(action: back) { ToolLabel(title: t("Notes", "Note"), symbol: "chevron.left") }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                    .help(t("All the notes", "Tutte le note"))
            }
            if panel {
                Button { model.newNote() } label: { ToolLabel(title: t("New note", "Nuova nota"), symbol: "square.and.pencil") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).keyboardShortcut("n", modifiers: .command)
                if model.meeting == .idle {
                    Button { model.startMeeting() } label: { ToolLabel(title: t("Record a meeting", "Registra una riunione"), symbol: "person.2.wave.2") }
                        .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.busy)
                        .help(t("Records your microphone and the sound of the Mac, then writes the notes here. Tell the others you are recording.", "Registra il tuo microfono e l’audio del Mac, poi scrive qui le note. Avvisa gli altri che stai registrando."))
                }
            }
            Button { model.handsFree = true; model.begin() } label: { ToolLabel(title: t("Dictate", "Detta"), symbol: "mic") }
                .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.busy)
                .help(model.keysCantFinish ? t("Dictates into the note where the cursor is. Finish it from the overlay or the menu.", "Detta nella nota dove si trova il cursore. Terminala dalla capsula o dal menu.")
                                           : t("Dictates into the note where the cursor is. Space finishes.", "Detta nella nota dove si trova il cursore. Spazio termina."))
            Menu {
                ForEach(Array(model.library.transforms.enumerated()), id: \.element.id) { index, transform in
                    Button(transform.name) { model.transformNote(index) }
                }
            } label: { ToolLabel(title: t("Transform", "Trasforma"), symbol: "wand.and.stars") }
                .menuStyle(.button).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).fixedSize().disabled(model.busy)
                .help(t("Rewrites the selection, or the whole note, with a transform.", "Riscrive la selezione, o tutta la nota, con una trasformazione."))
            Spacer()
            if more {
                Menu {
                    Button { model.copy(text) } label: { ToolLabel(title: t("Copy the note", "Copia la nota"), symbol: "doc.on.doc") }
                    ShareLink(item: note.url) { ToolLabel(title: t("Share the note", "Condividi la nota"), symbol: "square.and.arrow.up") }
                    Button { model.exportNote(note) } label: { ToolLabel(title: t("Export as a Word document", "Esporta come documento Word"), symbol: "doc.richtext") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([note.url]) } label: { ToolLabel(title: t("Show in Finder", "Mostra nel Finder"), symbol: "folder") }
                    Divider()
                    Button(role: .destructive) { model.trashNote(note.url) } label: { ToolLabel(title: t("Move to Trash", "Sposta nel Cestino"), symbol: "trash") }
                } label: { ToolIcon(symbol: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).fixedSize()
                    .help(t("More for this note", "Altro per questa nota")).accessibilityLabel(t("More for this note", "Altro per questa nota"))
            } else {
                fileTools
            }
        }
    }
    /// What is done with the note's file, one style for every tool on the bar.
    @ViewBuilder private var fileTools: some View {
        Button { model.copy(text) } label: { ToolIcon(symbol: "doc.on.doc") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .help(t("Copy the note", "Copia la nota")).accessibilityLabel(t("Copy the note", "Copia la nota"))
        ShareLink(item: note.url) { ToolIcon(symbol: "square.and.arrow.up") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .help(t("Share the note: Mail, Messages, AirDrop, Notes", "Condividi la nota: Mail, Messaggi, AirDrop, Note")).accessibilityLabel(t("Share the note", "Condividi la nota"))
        Button { model.exportNote(note) } label: { ToolIcon(symbol: "doc.richtext") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .help(t("Export as a Word document", "Esporta come documento Word")).accessibilityLabel(t("Export as a Word document", "Esporta come documento Word"))
        Button { NSWorkspace.shared.activateFileViewerSelecting([note.url]) } label: { ToolIcon(symbol: "folder") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .help(t("Show in Finder", "Mostra nel Finder")).accessibilityLabel(t("Show in Finder", "Mostra nel Finder"))
        Button(role: .destructive) { model.trashNote(note.url) } label: { ToolIcon(symbol: "trash") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .help(t("Move to Trash", "Sposta nel Cestino")).accessibilityLabel(t("Move to Trash", "Sposta nel Cestino"))
    }
}

/// A tool's icon in the same 16 pt box whatever its glyph, so icon buttons come out the same size.
private struct ToolIcon: View {
    let symbol: String
    var body: some View { Image(systemName: symbol).frame(width: 16, height: 16) }
}
private struct ToolLabel: View {
    let title: String
    let symbol: String
    var body: some View { Label { Text(title) } icon: { ToolIcon(symbol: symbol) } }
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
        // A note's lines keep a readable measure however wide the window.
        view.measure = practice ? nil : Sizing.columnEditor
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
        /// The longest a line gets, from the inset; nil, as wide as the view.
        var measure: CGFloat?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let measure, let container = textContainer else { return }
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: max(0, min(measure + container.lineFragmentPadding * 2, newSize.width - textContainerInset.width * 2)), height: .greatestFiniteMagnitude)
        }
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
