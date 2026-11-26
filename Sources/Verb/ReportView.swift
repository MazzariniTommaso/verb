import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import VerbCore

/// Report a problem: what happened in your words, with the details that help find the cause.
/// Nothing is sent by itself: the report opens as a new issue on GitHub, or is saved as a file.
struct ReportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var includeLog = true
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(t("Report a problem", "Segnala un problema")).font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
                Text(t("Nothing is sent by itself. The report opens on GitHub, where you read it before you send it, or is saved as a file.",
                       "Nulla parte da solo. La segnalazione si apre su GitHub, dove la leggi prima di inviarla, oppure si salva in un file."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VerbField(label: t("In a few words", "In poche parole"), text: $title, prompt: t("The paste goes to the wrong field in Slack", "Il testo va nel campo sbagliato su Slack"))
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("What happened, and what you expected", "Cosa è successo, e cosa ti aspettavi"))
                VerbEditor(text: $description, minHeight: 120, label: t("What happened", "Cosa è successo"))
            }
            Toggle(isOn: $includeLog) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Include Verb’s recent log", "Includi il registro recente di Verb")).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textPrimary)
                    Text(t("The last half hour of what Verb noted about the microphone, the models and the keys. No dictations.", "L’ultima mezz’ora di ciò che Verb ha annotato su microfono, modelli e tasti. Nessuna dettatura."))
                        .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Palette.controlOn)
            Text(t("Added: Verb’s version, the Mac’s system and model, and how Verb is set up (models, styles, keys). Never your words, dictionary or keys.",
                   "Si aggiungono: la versione di Verb, il sistema e il modello del Mac, e come è configurato Verb (modelli, stili, tasti). Mai le tue parole, il dizionario o le chiavi."))
                .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Button(t("Cancel", "Annulla")) { dismiss() }.buttonStyle(VerbButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save as a file…", "Salva in un file…")) { save() }.buttonStyle(VerbButtonStyle(kind: .secondary))
                Button(t("Open on GitHub", "Apri su GitHub")) { open() }.buttonStyle(VerbButtonStyle(kind: .primary)).disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 560)
        .background(Palette.surfacePage)
    }

    private var report: String {
        Diagnostics.report(description: description, version: AppInfo.version, system: ProcessInfo.processInfo.operatingSystemVersionString, hardware: Self.hardware,
                           settings: model.settings, log: includeLog ? Self.recentLog() : [])
    }
    private func open() {
        guard let url = Diagnostics.issueURL(title: title.isEmpty ? t("A problem", "Un problema") : title, body: report) else { return }
        NSWorkspace.shared.open(url)
        dismiss()
    }
    private func save() {
        let panel = NSSavePanel(); panel.prompt = t("Save", "Salva"); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = t("Verb-report.md", "Verb-segnalazione.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(("# " + (title.isEmpty ? t("A problem", "Un problema") : title) + "\n\n" + report).utf8).write(to: url, options: .atomic); dismiss() }
        catch { model.notify(error.localizedDescription) }
    }
    /// The Mac's model, as "Mac15,6", and its memory.
    static var hardware: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return String(cString: model) + ", \(memory) GB"
    }
    /// What Verb wrote to the system log in the last half hour.
    static func recentLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date().addingTimeInterval(-1800))
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        guard let entries = try? store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", "app.verb.dictation")) else { return [] }
        return entries.compactMap { $0 as? OSLogEntryLog }.map { "\(formatter.string(from: $0.date)) \($0.category): \($0.composedMessage)" }
    }
}
