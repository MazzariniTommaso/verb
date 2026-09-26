import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import VerbCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.previewingDrop) private var previewingDrop
    @State private var search = ""
    @State private var detail: DictationRecord?
    /// A file is being dragged over the page, and Verb is free to take it.
    @State private var dropping = false

    private var filtered: [DictationRecord] {
        model.history.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.rawText.localizedCaseInsensitiveContains(search) || $0.appName.localizedCaseInsensitiveContains(search) }
    }
    /// Entries grouped by day, newest first, like dated pages in a notebook.
    private var days: [(day: Date, records: [DictationRecord])] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { (day: $0.key, records: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        PageScroll {
            PageHeader(rubric: rubric, title: t("History", "Cronologia"), detail: t("Search, compare, copy or recover anything you said.", "Cerca, confronta, copia o recupera ciò che hai detto.")) {
                HStack(spacing: Space.sm) {
                    Button { model.importAudio() } label: { Label(t("Import audio…", "Importa audio…"), systemImage: "square.and.arrow.down") }
                        .buttonStyle(VerbButtonStyle(kind: .secondary)).disabled(model.busy)
                        .help(t("Transcribe a recording like a dictation. You can also drop an audio file on this page.", "Trascrivi una registrazione come una dettatura. Puoi anche trascinare un file audio su questa pagina."))
                    Button { model.exportHistory() } label: { Label(t("Export", "Esporta"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(VerbButtonStyle(kind: .secondary)).disabled(model.history.isEmpty)
                }
                // The buttons keep their words; the line under the title wraps instead.
                .fixedSize()
            }
            if !model.history.isEmpty {
                SearchField(text: $search, prompt: t("Search words or apps", "Cerca parole o app"), clearLabel: t("Clear search", "Cancella la ricerca"))
            }
            if filtered.isEmpty {
                Card {
                    if search.isEmpty {
                        EmptyState(symbol: "clock.arrow.circlepath", title: t("A fresh page", "Una pagina bianca"),
                                   detail: t("Your dictations will be kept here. You choose for how long in Settings.", "Qui troverai le tue dettature. Per quanto tempo, lo decidi nelle Impostazioni."))
                    } else {
                        EmptyState(symbol: "magnifyingglass", title: t("Nothing matches", "Nessun risultato"),
                                   detail: t("Try another word or the name of an app.", "Prova con un’altra parola o con il nome di un’app."))
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(days, id: \.day) { group in
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Overline(text: dayTitle(group.day)).padding(.leading, Space.xs)
                            RowList {
                                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                    if index > 0 { Hairline().padding(.horizontal, Space.lg) }
                                    HistoryRow(record: record) { detail = record }
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay { if dropping || previewingDrop { AudioDropSheet().transition(.opacity) } }
        .animation(.easeOut(duration: Motion.fast), value: dropping)
        .onDrop(of: [.fileURL], delegate: AudioDrop(model: model, dropping: $dropping))
        .sheet(item: $detail) { HistoryDetail(record: $0).environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale) }
    }

    private var rubric: String {
        let count = t.count(model.history.count, "dictation", "dictations", "dettatura", "dettature")
        switch model.settings.retention {
        case .none: return count + " · " + t("history is off", "cronologia disattivata")
        case .forever: return count + " · " + t("kept until you delete them", "conservate finché non le elimini")
        default: return count + " · " + t("kept ", "conservate ") + model.settings.retention.title(t)
        }
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return t("Today", "Oggi") }
        if Calendar.current.isDateInYesterday(day) { return t("Yesterday", "Ieri") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(t.locale))
    }
}

/// Takes one file dragged onto History and imports it. While Verb is busy the page refuses
/// the drag, as the Import button is off.
private struct AudioDrop: DropDelegate {
    let model: AppModel
    @Binding var dropping: Bool
    func validateDrop(info: DropInfo) -> Bool { !model.busy && info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { dropping = true }
    func dropExited(info: DropInfo) { dropping = false }
    func performDrop(info: DropInfo) -> Bool {
        dropping = false
        let files = info.itemProviders(for: [.fileURL])
        guard files.count < 2 else { model.notify("Import one recording at a time."); return false }
        guard let file = files.first, !model.busy else { return false }
        // Whether the file is audio Verb can read is checked on import, which says so if it isn't.
        _ = file.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.importAudio(from: url) }
        }
        return true
    }
}

/// What History shows while a file is dragged over it: one sheet, ready to take the recording.
private struct AudioDropSheet: View {
    @Environment(\.lang) private var t
    var body: some View {
        EmptyState(symbol: "waveform", title: t("Drop to transcribe", "Rilascia per trascrivere"),
                   detail: t("Verb writes it down like a dictation. Up to 4 hours on this Mac.", "Verb la trascrive come una dettatura. Fino a 4 ore su questo Mac."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            // The sheet lies where the page's column does.
            .padding(.horizontal, Space.page).padding(.vertical, Space.xxxl + Space.xs)
            .frame(maxWidth: Sizing.contentMax + Space.page * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surfacePage)
            .allowsHitTesting(false)
    }
}

private struct PreviewingDropKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Shows History as it looks while a file is dragged over it, for the snapshot renderer.
    var previewingDrop: Bool {
        get { self[PreviewingDropKey.self] }
        set { self[PreviewingDropKey.self] = newValue }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let action: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var hovering = false
    private var needsRecovery: Bool { record.status == .failed || record.status == .cancelled }
    private var hasAudio: Bool { record.audioName.flatMap { model.paths.audioURL($0) }.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(record.text.isEmpty ? t("No text", "Nessun testo") : record.text)
                    .font(record.text.isEmpty ? Typeface.display(TypeSize.callout).italic() : Typeface.display(TypeSize.callout))
                    .foregroundStyle(record.text.isEmpty ? Palette.textTertiary : Palette.textPrimary)
                    .lineSpacing(leading(TypeSize.callout, Leading.ui)).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Space.sm) {
                    Image(systemName: record.mode == .command ? "pencil.line" : "text.bubble").font(.system(size: 11)).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                    Text([t.message(record.appName), record.createdAt.formatted(.dateTime.hour().minute().locale(t.locale)), t.count(record.wordCount, "word", "words", "parola", "parole"), t.duration(record.duration)].joined(separator: " · "))
                        .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Spacer(minLength: Space.sm)
                    if needsRecovery && hasAudio { StatusLabel(text: t("Recover recording", "Recupera la registrazione"), symbol: "arrow.clockwise", tone: .warning) }
                    else if needsRecovery { StatusLabel(text: t("Not finished", "Non completata"), symbol: "exclamationmark.triangle", tone: .warning) }
                    else if !record.delivery.isEmpty, Outcome.of(delivery: record.delivery) != .delivered { Text(t.outcome(record.delivery)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary).lineLimit(1) }
                }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Palette.fillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .accessibilityHint(t("Opens the entry", "Apre la voce"))
    }
}

struct HistoryDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    let record: DictationRecord
    @State private var original = false
    @State private var draft = ""
    @State private var player: AVAudioPlayer?
    @State private var confirmDelete = false
    private var failed: Bool { record.status == .failed || record.status == .cancelled }
    private var nothingToCopy: Bool { (original ? record.rawText : draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var audio: URL? {
        guard let name = record.audioName, let url = model.paths.audioURL(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Rubric(text: t.dateAndTime(record.createdAt))
                    Text(t.message(record.appName)).font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary)
                }
                Spacer()
                Button(t("Done", "Fine")) { dismiss() }.buttonStyle(VerbButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
            }
            if !(record.text.isEmpty && record.rawText.isEmpty) {
                Segmented(title: t("Version", "Versione"), values: [false, true], selection: $original) { $0 ? t("Original transcript", "Trascrizione originale") : t("Final text", "Testo finale") }
                    .frame(maxWidth: 380)
            }
            if record.text.isEmpty && record.rawText.isEmpty {
                EmptyState(symbol: "waveform.slash", title: t("Nothing was transcribed", "Non è stato trascritto nulla"),
                           // One message, from what is actually true: with the audio, the engine's advice applies; without it, nothing can be retried.
                           detail: audio == nil ? t("The recording is no longer kept, so there is nothing to retry.", "La registrazione non è più conservata, quindi non c’è nulla da riprovare.")
                                                : record.error.map { t.message($0) } ?? t("Listen to the recording, then retry it.", "Ascolta la registrazione, poi riprovala."))
                    .frame(minHeight: 240)
                    .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            } else if original {
                ScrollView {
                    Text(record.rawText.isEmpty ? t("No transcript.", "Nessuna trascrizione.") : record.rawText)
                        .font(Typeface.display(TypeSize.reading)).lineSpacing(leading(TypeSize.reading, Leading.reading)).foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
                }
                .frame(minHeight: 240)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            } else {
                VerbEditor(text: $draft, serif: true, minHeight: 240, label: t("Dictation text", "Testo della dettatura"))
            }
            if let error = record.error, !(record.text.isEmpty && record.rawText.isEmpty) { StatusLabel(text: t.message(error), symbol: "exclamationmark.triangle", tone: .warning).textSelection(.enabled) }
            if failed && record.mode == .command {
                Text(t("A voice edit can’t be retried from here: select the original text again and say your instruction.", "Una modifica a voce non si riprova da qui: seleziona di nuovo il testo originale e ripeti l’istruzione."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Text([t.engine(record.engine), t.spokenLanguage(record.language), t("\(record.processingSeconds.formatted(.number.precision(.fractionLength(1)).locale(t.locale))) s processing", "\(record.processingSeconds.formatted(.number.precision(.fractionLength(1)).locale(t.locale))) s di elaborazione")].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
            Hairline()
            HStack(spacing: Space.sm) {
                if let audio {
                    Button { do { player = try AVAudioPlayer(contentsOf: audio); player?.play() } catch { model.notify(error.localizedDescription) } } label: { Label(t("Listen", "Ascolta"), systemImage: "play.fill") }
                        .buttonStyle(VerbButtonStyle(kind: .secondary))
                    if record.mode == .dictation {
                        Button { model.retry(record); dismiss() } label: { Label(t("Retry", "Riprova"), systemImage: "arrow.clockwise") }
                            .buttonStyle(VerbButtonStyle(kind: failed ? .primary : .secondary)).disabled(model.busy)
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label(t("Delete", "Elimina"), systemImage: "trash") }
                    .buttonStyle(VerbButtonStyle(kind: .danger)).disabled(model.busy)
                Spacer()
                if !original && draft != record.text {
                    Button(t("Save edit", "Salva la modifica")) { model.saveEdited(record, text: draft); dismiss() }.buttonStyle(VerbButtonStyle(kind: .secondary))
                }
                if !nothingToCopy {
                    Button { model.copy(original ? record.rawText : draft) } label: { Label(t("Copy", "Copia"), systemImage: "doc.on.doc") }
                        .buttonStyle(VerbButtonStyle(kind: failed && audio != nil && record.mode == .dictation ? .secondary : .primary))
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 680)
        .background(Palette.surfacePage)
        .confirmationDialog(t("Delete this dictation?", "Eliminare questa dettatura?"), isPresented: $confirmDelete) {
            Button(t("Delete dictation", "Elimina la dettatura"), role: .destructive) { model.delete(record); dismiss() }
            Button(t("Cancel", "Annulla"), role: .cancel) {}
        } message: {
            Text(t("The text and its recording are removed from this Mac.", "Il testo e la sua registrazione vengono rimossi da questo Mac."))
        }
        .onAppear { draft = record.text; if record.text.isEmpty && !record.rawText.isEmpty { original = true } }
        .onDisappear { player?.stop() }
    }
}

