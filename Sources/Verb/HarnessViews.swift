import AppKit
import SwiftUI
import VerbCore
import VerbEngine

extension AppModel {
    var harnessExecutable: String? { HarnessClient.executable(for: settings.harnessOptions.provider, override: settings.harnessOptions.executable) }
    var harnessCatalog: HarnessCatalog? {
        guard let catalog = harnessCatalogs[settings.harnessOptions.provider.rawValue], catalog.executable == harnessExecutable else { return nil }
        return catalog
    }
    func selectHarness(_ provider: HarnessProvider) {
        guard !busy else { return }
        harnessTestTask?.cancel(); harnessTestResult = nil
        var updated = settings; updated.cleanupProvider = .harness; updated.harnessOptions.provider = provider; settings = updated
        refreshHarness()
    }
    func refreshHarness() {
        harnessTask?.cancel(); harnessError = nil
        // Reading the account and the models reaches the provider too: only with remote processing allowed.
        guard settings.allowRemoteProcessing else { harnessLoading = false; harnessError = "Allow remote processing to read your account and model list."; return }
        harnessLoading = true
        let request = UUID(); harnessRequest = request
        let options = settings.harnessOptions
        harnessTask = Task {
            defer { if harnessRequest == request { harnessLoading = false } }
            do {
                let catalog = try await HarnessClient().discover(options.provider, override: options.executable)
                try Task.checkCancellation()
                guard harnessRequest == request, settings.harnessOptions.provider == options.provider, settings.harnessOptions.executable == options.executable else { return }
                harnessCatalogs[options.provider.rawValue] = catalog
                try JSONStore.save(harnessCatalogs, to: paths.root.appendingPathComponent("harness-catalogs.json"))
            } catch is CancellationError { }
            catch { if harnessRequest == request { harnessError = error.localizedDescription } }
        }
    }
    func testHarness() {
        guard !harnessTesting, !busy else { return }
        let snapshot = settings
        harnessTesting = true; harnessTestResult = nil
        harnessTestTask = Task {
            defer { harnessTesting = false }
            let start = Date()
            do {
                let result = try await client.edit(text: "Ehm, il gatto è sul divano, anzi sulla sedia.", style: .natural, vocabulary: [], settings: snapshot, key: "")
                try Task.checkCancellation()
                harnessTestResult = "\(snapshot.harnessOptions.provider.title) · \(String(format: "%.1f", Date().timeIntervalSince(start))) s\n\(result)"
            } catch is CancellationError { harnessTestResult = "Test cancelled." }
            catch { harnessTestResult = error.localizedDescription }
        }
    }
}

/// Cleanup through a CLI you are already signed in to: Claude Code, Codex, Cursor, Gemini or Copilot.
struct HarnessConnectionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var executable = ""
    private var provider: HarnessProvider { model.settings.harnessOptions.provider }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(t("Speech can stay on this Mac. Only the transcript goes to your signed-in CLI, for cleanup, voice edits and transforms.", "La voce può restare su questo Mac. Solo la trascrizione va alla CLI a cui hai fatto l’accesso, per rifiniture, modifiche a voce e trasformazioni."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading)).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Space.base) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: t("Provider", "Fornitore"))
                    Picker(t("Provider", "Fornitore"), selection: Binding(get: { provider }, set: { model.selectHarness($0) })) { ForEach(HarnessProvider.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: t("Model from your CLI", "Modello dalla tua CLI"))
                    Picker(t("Model from your CLI", "Modello dalla tua CLI"), selection: $model.settings.harnessOptions.model) {
                        Text(t("Choose a model…", "Scegli un modello…")).tag("")
                        if !model.settings.harnessOptions.model.isEmpty, model.harnessCatalog?.models.contains(where: { $0.id == model.settings.harnessOptions.model }) != true {
                            Text(model.settings.harnessOptions.model + t(" · unavailable", " · non disponibile")).tag(model.settings.harnessOptions.model)
                        }
                        ForEach(model.harnessCatalog?.models ?? []) { Text(t.message($0.name)).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).disabled(model.harnessLoading || model.harnessCatalog == nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.harnessTesting || model.busy)
            HStack(spacing: Space.sm) {
                if model.harnessLoading {
                    ProgressView().controlSize(.small)
                    Text(t("Reading your account and model list…", "Leggo account ed elenco dei modelli…")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                } else if model.harnessExecutable == nil {
                    StatusLabel(text: t("CLI not found", "CLI non trovata"), symbol: "terminal", tone: .warning)
                } else if let account = model.harnessCatalog?.account {
                    StatusLabel(text: t.message(account), symbol: "checkmark.circle", tone: .success)
                } else {
                    StatusLabel(text: t("Ready to connect", "Pronta al collegamento"), symbol: "terminal")
                }
                Spacer()
                Button { model.refreshHarness() } label: { Label(t("Refresh models", "Aggiorna i modelli"), systemImage: "arrow.clockwise") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.harnessLoading || model.harnessTesting || model.busy)
            }
            if let error = model.harnessError { StatusLabel(text: t.message(error), symbol: "exclamationmark.triangle", tone: .warning).textSelection(.enabled) }
            if let catalog = model.harnessCatalog {
                let stale = Date().timeIntervalSince(catalog.fetchedAt) > 900
                Text(t("Updated \(catalog.fetchedAt.formatted(.dateTime.day().month().hour().minute().locale(t.locale))) · \(catalog.models.count) models", "Aggiornato \(catalog.fetchedAt.formatted(.dateTime.day().month().hour().minute().locale(t.locale))) · \(catalog.models.count) modelli")
                     + (stale ? t(" · cached, refresh for current availability", " · in cache, aggiorna per la disponibilità attuale") : ""))
                    .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
                if let selected = catalog.models.first(where: { $0.id == model.settings.harnessOptions.model }) {
                    Text(selected.detail.isEmpty ? selected.id : selected.detail).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
                }
            }
            Hairline()
            // Usable while a dictation runs, so it can be turned off mid-way.
            SwitchRow(title: t("Allow remote processing", "Consenti l’elaborazione remota"), detail: t.message(provider.billingNote), isOn: $model.settings.allowRemoteProcessing)
            HStack(spacing: Space.sm) {
                Button(model.harnessTesting ? t("Testing…", "Test in corso…") : t("Test with sample text", "Prova con un testo d’esempio")) { model.testHarness() }
                    .buttonStyle(VerbButtonStyle(kind: .secondary)).disabled(model.harnessTesting || !model.writerReady)
                if model.harnessTesting { Button(t("Cancel", "Annulla")) { model.harnessTestTask?.cancel() }.buttonStyle(VerbButtonStyle(kind: .quiet)) }
                Text(t("Uses your plan’s quota", "Usa la quota del tuo piano")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
            }
            .disabled(model.busy)
            if let result = model.harnessTestResult {
                Text(t.message(result)).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).textSelection(.enabled)
                    .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(t("Install the official CLI, then sign in from Terminal with your subscription account. Verb uses that login; it never copies credentials or falls back to an API key.",
                           "Installa la CLI ufficiale, poi accedi dal Terminale con il tuo account in abbonamento. Verb usa quell’accesso: non copia mai le credenziali e non ripiega su una chiave API."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.sm) {
                        Text(provider.loginCommand).font(Typeface.mono(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).textSelection(.enabled)
                            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs).background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        Button(t("Copy command", "Copia il comando")) { model.copy(provider.loginCommand) }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                        Spacer()
                        Link(destination: provider.documentation) { Label(t("Installation guide", "Guida all’installazione"), systemImage: "arrow.up.right") }
                            .font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.accent)
                    }
                    Text(model.harnessExecutable ?? t("No executable detected", "Nessun eseguibile trovato")).font(Typeface.mono(TypeSize.caption)).foregroundStyle(Palette.textTertiary).textSelection(.enabled)
                    HStack(alignment: .bottom, spacing: Space.sm) {
                        VerbField(label: t("Executable path (optional)", "Percorso dell’eseguibile (facoltativo)"), text: $executable, mono: true)
                        Button(t("Apply", "Applica")) { model.settings.harnessOptions.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines); model.refreshHarness() }
                            .buttonStyle(VerbButtonStyle(kind: .secondary)).padding(.bottom, -4)
                    }
                    Text(t("Leave the path empty to detect it automatically. Refresh asks the provider for its current catalog; Verb never substitutes a fixed list.", "Lascia vuoto il percorso per trovarlo in automatico. Aggiorna chiede al fornitore il catalogo attuale; Verb non usa mai un elenco fisso."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.sm)
            } label: {
                Text(t("Connection and CLI setup", "Collegamento e configurazione della CLI")).font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary)
            }
            .disabled(model.harnessTesting || model.busy)
        }
        .onAppear { executable = model.settings.harnessOptions.executable; if Date().timeIntervalSince(model.harnessCatalog?.fetchedAt ?? .distantPast) > 60 { model.refreshHarness() } }
        .onChange(of: provider) { _, _ in executable = model.settings.harnessOptions.executable }
    }
}
