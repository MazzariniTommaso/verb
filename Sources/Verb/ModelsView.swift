import SwiftUI
import VerbCore

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        PageScroll {
            PageHeader(rubric: rubric, title: t("Models", "Modelli"),
                       detail: t("Speech recognition catches the words. A writing model tidies them. Each runs where you choose.", "Il riconoscimento vocale raccoglie le parole. Un modello di scrittura le mette in ordine. Ognuno lavora dove scegli tu."))
            speech.disabled(model.busy)
            writing
            MemoryCard(resources: model.resources).disabled(model.busy)
            if model.downloadingSpeech || model.downloadingWriter { download }
            Text(t("A local failure never switches to a hosted provider on its own.", "Un errore locale non passa mai da solo a un fornitore esterno."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
        }
    }

    private var rubric: String {
        let speech = model.settings.speechProvider == .onDevice ? t("on this Mac", "su questo Mac") : t("hosted", "esterna")
        let writing: String
        switch model.settings.cleanupProvider {
        case .local: writing = t("on this Mac", "su questo Mac")
        case .harness: writing = model.settings.harnessOptions.provider.title
        case .endpoint: writing = t("hosted", "esterna")
        case .off: writing = t("off", "disattivata")
        }
        return t("Speech \(speech) · Writing \(writing)", "Voce \(speech) · Scrittura \(writing)")
    }

    private var speech: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(numeral: "1", title: t("Speech recognition", "Riconoscimento vocale"))
                Spacer()
                if model.settings.speechProvider == .onDevice {
                    if model.speechInstalled { StatusLabel(text: t("Ready offline", "Pronto offline"), symbol: "checkmark.circle", tone: .success) }
                    else { StatusLabel(text: t("Needs download", "Da scaricare"), symbol: "arrow.down.circle", tone: .warning) }
                } else { StatusLabel(text: t("Custom endpoint", "Endpoint personale"), symbol: "network", tone: .warning) }
            }
            ChoiceCards(title: t("Where speech recognition runs", "Dove lavora il riconoscimento vocale"), values: SpeechProvider.allCases, selection: $model.settings.speechProvider, label: { $0.title(t) }, detail: { $0.detail(t) })
                .padding(.top, Space.lg)
            if model.settings.speechProvider == .onDevice {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(title: t("MLX model", "Modello MLX"), detail: (try? SpeechCatalog.model(model.settings.localModel).detail).map { t.message($0) }) {
                        Picker(t("MLX model", "Modello MLX"), selection: $model.settings.localModel) { ForEach(SpeechCatalog.models) { Text($0.name).tag($0.id) } }
                            .labelsHidden().pickerStyle(.menu).frame(width: 240).disabled(model.downloadingSpeech)
                    }
                    Hairline()
                    Text(model.settings.localModel == "parakeet-v3"
                         ? t("Native MLX on the Apple GPU. Parakeet detects the spoken language by itself; your dictionary still applies after recognition.", "MLX nativo sulla GPU Apple. Parakeet riconosce da solo la lingua parlata; il tuo dizionario si applica comunque dopo il riconoscimento.")
                         : t("Native MLX on the Apple GPU. Qwen follows the language setting and your vocabulary hints.", "MLX nativo sulla GPU Apple. Qwen segue l’impostazione della lingua e i suggerimenti del dizionario."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, Space.md)
                    if !model.speechInstalled {
                        Button(t("Download MLX model", "Scarica il modello MLX")) { model.downloadSpeech() }
                            .buttonStyle(VerbButtonStyle(kind: .primary)).disabled(model.downloadingSpeech || model.downloadingWriter)
                    }
                }
                .padding(.top, Space.md)
            } else {
                VStack(alignment: .leading, spacing: Space.md) {
                    VerbField(label: t("Transcription endpoint", "Endpoint di trascrizione"), text: $model.settings.speechEndpoint, mono: true)
                    VerbField(label: t("Model ID", "ID del modello"), text: $model.settings.speechModel, mono: true)
                    KeyField(name: "speech", title: t("API key", "Chiave API"))
                    Text(t("Accepts multipart audio and a JSON response with a text field: a provider’s endpoint or your own compatible server. Remote HTTPS endpoints need Remote processing in Settings.",
                           "Accetta audio multipart e una risposta JSON con un campo text: l’endpoint di un fornitore o un tuo server compatibile. Gli endpoint HTTPS remoti richiedono l’Elaborazione remota nelle Impostazioni."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.lg)
            }
        }
    }

    private var writing: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(numeral: "2", title: t("Writing and cleanup", "Scrittura e rifinitura"))
                Spacer()
                if model.writerReady { StatusLabel(text: t("Ready", "Pronto"), symbol: "checkmark.circle", tone: .success) }
                else { StatusLabel(text: t("Needs setup", "Da configurare"), symbol: "exclamationmark.circle", tone: .warning) }
            }
            // While a dictation runs, only remote processing can change (see HarnessConnectionView).
            ChoiceCards(title: t("Writing model", "Modello di scrittura"), values: CleanupProvider.allCases, selection: $model.settings.cleanupProvider, label: { $0.title(t) }, detail: { $0.detail(t) })
                .padding(.top, Space.lg).disabled(model.harnessTesting || model.busy)
            if model.settings.cleanupProvider != .off { policy.padding(.top, Space.lg).disabled(model.busy) }
            Group {
                switch model.settings.cleanupProvider {
                case .local: local.disabled(model.busy)
                case .harness: HarnessConnectionView()
                case .endpoint:
                    VStack(alignment: .leading, spacing: Space.md) {
                        VerbField(label: t("Chat completions endpoint", "Endpoint chat completions"), text: $model.settings.cleanupEndpoint, mono: true)
                        VerbField(label: t("Model ID", "ID del modello"), text: $model.settings.hostedCleanupModel, mono: true)
                        KeyField(name: "cleanup", title: t("API key", "Chiave API"))
                        Text(t("Any API compatible with chat completions, including a model server you host. Keys are kept in the macOS Keychain.", "Qualsiasi API compatibile con chat completions, anche un server di modelli che ospiti tu. Le chiavi restano nel Portachiavi di macOS."))
                            .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(model.busy)
                case .off:
                    Text(t("Verb keeps the speech engine’s words, applies your dictionary and snippets, and skips AI cleanup. Voice editing and transforms need a writing model.",
                           "Verb tiene le parole del riconoscimento, applica dizionario e frasi pronte e salta la rifinitura AI. Modifica a voce e trasformazioni richiedono un modello di scrittura."))
                        .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Space.lg)
        }
    }

    /// When the writing model runs. The quick rules (fillers, stumbled repeats, spacing) run in every style but Verbatim.
    private var policy: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                RowLabel(title: t("Refine dictations", "Rifinisci le dettature"))
                Spacer()
                Segmented(title: t("Refine dictations", "Rifinisci le dettature"), values: CleanupPolicy.allCases, selection: $model.settings.cleanupPolicy, label: { $0.title(t) })
                    .frame(width: 330)
            }
            Text(model.settings.cleanupPolicy.detail(t) + " " + t("Fillers such as “ehm”, stumbled repeats and spacing are fixed on the spot, with no model, in every style but Verbatim.",
                                                                "Intercalari come “ehm”, ripetizioni inciampate e spazi si sistemano all’istante, senza modello, in ogni stile tranne Alla lettera."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var local: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(t("Verb starts a private Ollama service on this Mac, with its cloud features switched off. The default Qwen3 4B model is about 2.5 GB. Once loaded it tidies a sentence in well under two seconds, far quicker than a subscription, and it stays loaded as long as Memory says below.",
                   "Verb avvia un servizio Ollama privato su questo Mac, con le funzioni cloud spente. Il modello predefinito Qwen3 4B pesa circa 2,5 GB. Una volta caricato rifinisce una frase in molto meno di due secondi, ben più veloce di un abbonamento, e resta caricato per il tempo scelto in Memoria, qui sotto."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading)).fixedSize(horizontal: false, vertical: true)
            VerbField(label: t("Ollama model", "Modello Ollama"), text: $model.settings.cleanupModel, mono: true)
            HStack(spacing: Space.sm) {
                let installed = model.writerModels.contains(model.settings.cleanupModel)
                // The speech model comes first: while it's missing, its download is the page's one primary button.
                let first = model.speechInstalled || model.settings.speechProvider == .endpoint
                Button(installed ? t("Check for updates", "Controlla gli aggiornamenti") : t("Download writing model", "Scarica il modello di scrittura")) { model.downloadWriter() }
                    .buttonStyle(VerbButtonStyle(kind: installed || !first ? .secondary : .primary)).disabled(model.downloadingWriter || model.downloadingSpeech)
                Button(t("Refresh list", "Ricarica l’elenco")) {
                    Task { do { try await model.writer.start(); model.writerModels = try await model.client.localModels() } catch { model.notify(error.localizedDescription) } }
                }
                .buttonStyle(VerbButtonStyle(kind: .secondary))
                Spacer()
                if model.writerModels.contains(model.settings.cleanupModel) { StatusLabel(text: t("Ready on this Mac", "Pronto su questo Mac"), symbol: "checkmark.circle", tone: .success) }
            }
            if model.settings.cleanupModel != Self.lighterModel {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(t("Want it quicker still? Qwen3 1.7B (about 1.4 GB) is smaller and faster, with a little less care for long passages.",
                           "Lo vuoi ancora più rapido? Qwen3 1.7B (circa 1,4 GB) è più piccolo e più veloce, con un po’ meno cura sui testi lunghi."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.sm)
                    Button(t("Use Qwen3 1.7B", "Usa Qwen3 1.7B")) { model.settings.cleanupModel = Self.lighterModel }
                        .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)).fixedSize()
                }
            }
            if !model.writer.available {
                Link(destination: URL(string: "https://ollama.com/download/mac")!) { Label(t("Install Ollama", "Installa Ollama"), systemImage: "arrow.up.right") }
                    .font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.accent)
            }
        }
    }

    /// A smaller Ollama tag for people who want speed over polish. Choosing it only fills the
    /// field: the download starts from the button above, as for any other model.
    static let lighterModel = "qwen3:1.7b"

    private var download: some View {
        Card(padding: Space.lg) {
            HStack {
                Text(t.message(model.downloadStatus)).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Spacer()
                Text(model.downloadProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale))).font(Typeface.text(TypeSize.footnote)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                Button(t("Cancel", "Annulla")) { model.cancelDownload() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
            }
            ProgressView(value: model.downloadProgress).tint(Palette.controlOn).padding(.top, Space.sm)
        }
    }
}

/// A key saved to the macOS Keychain, never to settings.json.
struct KeyField: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let name: String
    let title: String
    @State private var value = ""
    @State private var saved = false
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            VerbField(label: title, text: $value, secure: true).onChange(of: value) { _, _ in saved = false }
            Button(t("Save key", "Salva la chiave")) {
                do { try Secrets.save(value, name: name); saved = true } catch { model.notify(error.localizedDescription) }
            }
            .buttonStyle(VerbButtonStyle(kind: .secondary)).padding(.bottom, -4).disabled(saved)
            if saved { StatusLabel(text: t("Saved in the Keychain", "Salvata nel Portachiavi"), symbol: "checkmark.circle", tone: .success).padding(.bottom, 6) }
        }
        .onAppear { value = Secrets.read(name) }
    }
}

/// How much memory the models take, and when Verb lets them go.
private struct MemoryCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var resources: ResourceMonitor
    @Environment(\.lang) private var t
    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(numeral: "3", title: t("Memory", "Memoria"))
                Spacer()
                Button(t("Free memory now", "Libera la memoria ora")) { Task { await model.freeMemory(); resources.sample() } }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.busy)
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(title: t("Verb, with the speech model", "Verb, con il modello vocale")) { value(resources.reading.map { bytes($0.verb) }) }
                Hairline()
                SettingRow(title: t("Writing model", "Modello di scrittura")) {
                    if model.settings.cleanupProvider == .local { value(resources.reading.map { $0.writer.map(bytes) ?? t("Not loaded", "Non caricato") }) }
                    else { value(t("Works outside Verb", "Lavora fuori da Verb")) }
                }
                Hairline()
                SettingRow(title: t("Processor", "Processore")) { value(resources.reading.map { "\(Int($0.cpu.rounded()))%" }) }
                Hairline()
                SettingRow(title: t("Free memory after", "Libera la memoria dopo"),
                           detail: t("Without dictating for this long, the models leave memory; the next dictation loads them again while you speak. The speech model stays while Verb listens for “Hey \(model.settings.voiceOptions.spokenName)”.",
                                     "Dopo questo tempo senza dettare i modelli escono dalla memoria; la dettatura successiva li ricarica mentre parli. Il modello vocale resta finché Verb ascolta “Ehi \(model.settings.voiceOptions.spokenName)”.")) {
                    Picker(t("Free memory after", "Libera la memoria dopo"), selection: $model.settings.idleMinutes) {
                        ForEach([5, 15, 30, 60], id: \.self) { minutes in Text(minutes == 60 ? t("1 hour", "1 ora") : "\(minutes) min").tag(minutes) }
                        Text(t("Never", "Mai")).tag(0)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 160)
                }
            }
            .padding(.top, Space.md)
        }
        .onAppear { resources.start() }
        .onDisappear { resources.stop() }
    }
    private func value(_ text: String?) -> some View {
        Text(text ?? "–").font(Typeface.text(TypeSize.body, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary)
            .accessibilityLabel(text ?? t("Not measured yet", "Non ancora misurato"))
    }
    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory) }
}
