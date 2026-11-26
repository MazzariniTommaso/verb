import AppKit
import SwiftUI
import VerbCore

/// Settings → Meetings: calls Verb offers to record, and the kinds of notes a meeting gets.
struct MeetingSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: t("Offer to record calls", "Proponi di registrare le chiamate"),
                      detail: t("When Zoom, Teams, Meet, FaceTime or Slack use the microphone, Verb asks.", "Quando Zoom, Teams, Meet, FaceTime o Slack usano il microfono, Verb te lo chiede."),
                      isOn: $model.settings.meetingDetection)
                .help(t("Verb checks which apps use the microphone, on this Mac. When the call ends, it asks whether to write the notes.", "Verb controlla quali app usano il microfono, su questo Mac. Quando la chiamata finisce, chiede se scrivere le note."))
            Hairline()
            SettingRow(title: t("Kind of notes", "Tipo di note"), detail: t("You can change it while the meeting runs.", "Puoi cambiarlo durante la riunione.")) {
                VerbPicker(title: t("Kind of notes", "Tipo di note"), selection: $model.settings.meetingTemplate, options: model.meetingKinds(t).map { ($0.id, $0.name) })
                    .frame(width: 220)
            }
            Hairline()
            HStack(alignment: .firstTextBaseline) {
                Text(t("Your kinds", "I tuoi tipi")).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    model.settings.customMeetingTemplates.append(MeetingTemplate(name: t("New kind", "Nuovo tipo"), instruction: ""))
                } label: { Label(t("Add a kind", "Aggiungi un tipo"), systemImage: "plus") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.top, Space.md)
            if model.settings.customMeetingTemplates.isEmpty {
                Text(t("Describe the notes you want, such as “decisions and owners only”, and choose it for a meeting.", "Descrivi le note che vuoi, come “solo decisioni e responsabili”, e sceglilo per una riunione."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).padding(.vertical, Space.sm)
            }
            ForEach($model.settings.customMeetingTemplates) { $kind in
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .bottom, spacing: Space.sm) {
                        VerbField(label: t("Name", "Nome"), text: $kind.name)
                        IconButton(symbol: "minus.circle", label: t("Remove \(kind.name)", "Rimuovi \(kind.name)")) {
                            let id = kind.id
                            model.settings.customMeetingTemplates.removeAll { $0.id == id }
                            if model.settings.meetingTemplate == id { model.settings.meetingTemplate = MeetingTemplate.general }
                        }
                    }
                    VerbEditor(text: $kind.instruction, minHeight: 60, label: t("What the notes should hold", "Cosa devono contenere le note"))
                }
                .padding(.vertical, Space.sm)
                Hairline()
            }
            Text(t("Let the others know you are recording.", "Avvisa gli altri che stai registrando.")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).padding(.vertical, Space.sm)
        }
    }
}

/// While a meeting records: the kind of notes, and a place to jot what matters, which the
/// summary follows and the note keeps.
struct MeetingNotesField: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var saving: Task<Void, Never>?
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text(t("Notes of kind", "Note di tipo")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                VerbPicker(title: t("Kind of notes", "Tipo di note"), selection: Binding(get: { model.meetingKind }, set: { model.setMeetingKind($0) }), options: model.meetingKinds(t).map { ($0.id, $0.name) })
                    .frame(width: 200)
                Spacer()
            }
            // A few lines, so the notes below keep their room; longer jottings scroll.
            VerbEditor(text: $model.meetingNotes, minHeight: compact ? 44 : 64, label: t("Your notes for this meeting", "I tuoi appunti per questa riunione"))
                .frame(maxHeight: compact ? 88 : 120)
                .overlay(alignment: .topLeading) {
                    if model.meetingNotes.isEmpty {
                        Text(t("Jot down what matters: the notes will follow it.", "Annota ciò che conta: le note lo seguiranno.")).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, Space.md + 5).padding(.vertical, Space.sm + 8).allowsHitTesting(false)
                    }
                }
        }
        .onChange(of: model.meetingNotes) { _, _ in
            saving?.cancel()
            saving = Task { try? await Task.sleep(nanoseconds: 800_000_000); guard !Task.isCancelled else { return }; model.saveMeetingNotes() }
        }
    }
}
