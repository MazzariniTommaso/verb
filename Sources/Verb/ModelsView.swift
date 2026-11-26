import AVFoundation
import SwiftUI
import VerbCore

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        PageScroll {
            PageHeader(rubric: rubric, title: t("Models", "Modelli"),
                       detail: t("Speech recognition catches the words. A writing model tidies them. Each runs where you choose.", "Il riconoscimento vocale raccoglie le parole. Un modello di scrittura le rifinisce. Ognuno lavora dove scegli tu."))
            speech.disabled(model.busy)
            writing
            MemoryCard(resources: model.resources).disabled(model.busy)
            if model.downloadingSpeech || model.downloadingWriter { download }
            Text(t("A local failure never switches to a hosted provider on its own.", "Un errore locale non passa mai da solo a un fornitore esterno."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
        }
    }

    private var rubric: String {
        let local = model.settings.speechProvider == .onDevice && model.settings.cleanupProvider == .local
        // Both here: said once.
        if local { return t("All on this Mac", "Tutto su questo Mac") }
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
                } else { StatusLabel(text: t("External server", "Server esterno"), symbol: "network", tone: .warning) }
            }
            ChoiceCards(title: t("Where speech recognition runs", "Dove lavora il riconoscimento vocale"), values: SpeechProvider.allCases, selection: $model.settings.speechProvider, label: { $0.title(t) }, detail: { $0.detail(t) })
                .padding(.top, Space.lg)
            if model.settings.speechProvider == .onDevice {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(title: t("Speech model", "Modello vocale"), detail: (try? SpeechCatalog.model(model.settings.localModel).detail).map { t.message($0) }) {
                        VerbPicker(title: t("Speech model", "Modello vocale"), selection: $model.settings.localModel, options: SpeechCatalog.models.map { ($0.id, t.engine($0.id)) })
                            .frame(width: 240).disabled(model.downloadingSpeech)
                    }
                    Hairline()
                    Text(model.settings.localModel.hasPrefix("parakeet")
                         ? t("Runs on the Mac’s own chip. Parakeet tells the spoken language by itself; your dictionary still applies after recognition.", "Lavora sul chip del Mac. Parakeet riconosce da solo la lingua parlata; il tuo dizionario si applica comunque dopo il riconoscimento.")
                         : t("Runs on the Mac’s own chip. Qwen follows the language setting and your dictionary’s hints.", "Lavora sul chip del Mac. Qwen segue l’impostazione della lingua e i suggerimenti del dizionario."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure().padding(.vertical, Space.md)
                    if !model.speechInstalled {
                        HStack(spacing: Space.sm) {
                            Button(model.downloadStopped ? t("Resume the download", "Riprendi il download") : t("Download the speech model", "Scarica il modello vocale")) { model.downloadSpeech() }
                                .buttonStyle(VerbButtonStyle(kind: .primary)).disabled(model.downloadingSpeech || model.downloadingWriter)
                            if model.downloadStopped, !model.downloadingSpeech { Text(t("Stopped. It carries on from where it was.", "Fermato. Riparte da dove era arrivato.")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary) }
                        }
                    }
                }
                .padding(.top, Space.md)
            } else {
                VStack(alignment: .leading, spacing: Space.md) {
                    VerbField(label: t("Transcription endpoint", "Endpoint di trascrizione"), text: $model.settings.speechEndpoint, mono: true)
                    EndpointCheck(value: model.settings.speechEndpoint)
                    VerbField(label: t("Model ID", "ID del modello"), text: $model.settings.speechModel, mono: true)
                    KeyField(name: "speech", title: t("API key", "Chiave API"))
                    EndpointTrialRow(stage: "speech", label: t("Try with a spoken sentence", "Prova con una frase detta")) { model.trySpeechEndpoint() }
                    Text(t("Accepts multipart audio and a JSON response with a text field: a provider’s endpoint or your own compatible server. Remote HTTPS endpoints need Remote processing in Settings.",
                           "Accetta audio multipart e una risposta JSON con un campo text: l’endpoint di un fornitore o un tuo server compatibile. Gli endpoint HTTPS remoti richiedono l’Elaborazione remota nelle Impostazioni."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
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
                        EndpointCheck(value: model.settings.cleanupEndpoint)
                        VerbField(label: t("Model ID", "ID del modello"), text: $model.settings.hostedCleanupModel, mono: true)
                        KeyField(name: "cleanup", title: t("API key", "Chiave API"))
                        EndpointTrialRow(stage: "writing", label: t("Try with a sample text", "Prova con un testo d’esempio")) { model.tryWritingEndpoint() }
                        Text(t("Any API compatible with chat completions, including a model server you host. Keys are kept in the macOS Keychain.", "Qualsiasi API compatibile con chat completions, anche un server di modelli che ospiti tu. Le chiavi restano nel Portachiavi di macOS."))
                            .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
                    }
                    .disabled(model.busy)
                case .off:
                    Text(t("Verb keeps the speech engine’s words, applies your dictionary and snippets, and skips AI cleanup. Voice editing and transforms need a writing model.",
                           "Verb tiene le parole del riconoscimento, applica dizionario e frasi pronte e salta la rifinitura AI. Modifica a voce e trasformazioni richiedono un modello di scrittura."))
                        .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading)).fixedSize(horizontal: false, vertical: true).measure()
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
                                                                "Intercalari come “ehm”, ripetizioni involontarie e spazi si sistemano all’istante, senza modello, in ogni stile tranne Alla lettera."))
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
        }
    }

    private var local: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(t("Verb starts a private Ollama service on this Mac, with its cloud features switched off. The default Qwen3 4B model is about 2.5 GB. Once loaded it tidies a sentence in well under two seconds, far quicker than a subscription, and it stays loaded as long as Memory says below. Verb keeps its own copy, apart from any Ollama you already use, so a model you have there downloads again.",
                   "Verb avvia un servizio Ollama privato su questo Mac, con le funzioni cloud spente. Il modello predefinito Qwen3 4B pesa circa 2,5 GB. Una volta caricato rifinisce una frase in molto meno di due secondi, ben più veloce di un abbonamento, e resta caricato per il tempo scelto in Memoria, qui sotto. Verb tiene una sua copia, separata da un Ollama che usi già, quindi un modello che hai lì si scarica di nuovo."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading)).fixedSize(horizontal: false, vertical: true).measure()
            VerbField(label: t("Ollama model", "Modello Ollama"), text: $model.settings.cleanupModel, mono: true)
            HStack(spacing: Space.sm) {
                let installed = model.writerModels.contains(model.settings.cleanupModel)
                // The speech model comes first: while it's missing, its download is the page's one primary button.
                let first = model.speechInstalled || model.settings.speechProvider == .endpoint
                // Without Ollama nothing can download: installing it is the step, in the button's place.
                if model.writer.available {
                    Button(installed ? t("Check for updates", "Controlla gli aggiornamenti") : t("Download writing model", "Scarica il modello di scrittura")) { model.downloadWriter() }
                        .buttonStyle(VerbButtonStyle(kind: installed || !first ? .secondary : .primary)).disabled(model.downloadingWriter || model.downloadingSpeech)
                } else {
                    Button { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) } label: { Label(t("Install Ollama", "Installa Ollama"), systemImage: "arrow.up.right") }
                        .buttonStyle(VerbButtonStyle(kind: first ? .primary : .secondary))
                }
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
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
                    Spacer(minLength: Space.sm)
                    Button(t("Use Qwen3 1.7B", "Usa Qwen3 1.7B")) { model.settings.cleanupModel = Self.lighterModel }
                        .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)).fixedSize()
                }
            }
            if !model.writer.available {
                Text(t("Ollama isn’t on this Mac. Until it is, Verb’s own rules tidy each dictation, with no waiting.", "Ollama non è su questo Mac. Finché non c’è, ci pensano le regole di Verb, senza attese."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true).measure()
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
                Button(t("Stop", "Ferma")) { model.cancelDownload() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
            }
            ProgressView(value: model.downloadProgress).tint(Palette.controlOn).padding(.top, Space.sm)
                .accessibilityLabel(t.message(model.downloadStatus)).accessibilityValue(model.downloadProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale)))
            let detail = model.downloadDetail(t)
            if !detail.isEmpty { Text(detail).font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textSecondary).padding(.top, Space.xs) }
        }
    }
}

/// A key saved to the macOS Keychain, never to settings.json. It is saved with the button, with
/// Return, or when you leave the page, so a key typed in is never lost.
struct KeyField: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let name: String
    let title: String
    @State private var value = ""
    @State private var stored = ""
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            VerbField(label: title, text: $value, secure: true).onSubmit(save)
            Button(t("Save key", "Salva la chiave"), action: save)
                .buttonStyle(VerbButtonStyle(kind: .secondary)).padding(.bottom, -4).disabled(value == stored)
            if value == stored, !stored.isEmpty { StatusLabel(text: t("In the Keychain", "Nel Portachiavi"), symbol: "checkmark.circle", tone: .success).padding(.bottom, 6) }
        }
        .onAppear { value = Secrets.read(name); stored = value }
        .onDisappear { if value != stored { save() } }
    }
    private func save() {
        guard value != stored else { return }
        do { try Secrets.save(value, name: name); stored = value } catch { model.notify(error.localizedDescription) }
    }
}

/// What is wrong with an endpoint's address, as soon as it is typed: not HTTPS, credentials in
/// it, or remote processing off.
private struct EndpointCheck: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let value: String
    var body: some View {
        if !value.isEmpty, let problem = problem {
            StatusLabel(text: t.message(problem), symbol: "exclamationmark.triangle", tone: .warning).textSelection(.enabled)
        }
    }
    private var problem: String? {
        do { _ = try EndpointPolicy.validate(value, allowRemote: model.settings.allowRemoteProcessing); return nil } catch { return error.localizedDescription }
    }
}

/// A button that tries an endpoint for real, and what came back.
private struct EndpointTrialRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let stage: String
    let label: String
    let action: () -> Void
    var body: some View {
        let trial = model.endpointTrials[stage]
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button(trial?.running == true ? t("Trying…", "Provo…") : label, action: action)
                    .buttonStyle(VerbButtonStyle(kind: .secondary)).disabled(trial?.running == true || model.busy)
                if trial?.running == true { ProgressView().controlSize(.small) }
            }
            if let trial, !trial.running { TrialResult(passed: trial.passed, text: t.message(trial.text)) }
        }
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
                    VerbPicker(title: t("Free memory after", "Libera la memoria dopo"), selection: $model.settings.idleMinutes,
                               options: [5, 15, 30, 60].map { ($0, $0 == 60 ? t("1 hour", "1 ora") : "\($0) min") } + [(0, t("Never", "Mai"))])
                        .frame(width: 160)
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
    private func bytes(_ count: UInt64) -> String { Int64(count).formatted(.byteCount(style: .memory).locale(t.locale)) }
}

/// How a try went: what came back, in the tone of a success or of a problem.
struct TrialResult: View {
    let passed: Bool
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: passed ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(passed ? Palette.success : Palette.warning).accessibilityHidden(true)
            Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(passed ? Palette.surfaceSunken : Palette.warningTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

extension AppModel {
    /// Sends a sample sentence to the writing server, with the key and model as set.
    func tryWritingEndpoint() {
        let snapshot = settings, sample = lang("Um, the cat is on the sofa, I mean on the chair.", "Ehm, il gatto è sul divano, anzi sulla sedia.")
        endpointTrials["writing"] = EndpointTrial(running: true)
        Task {
            let start = Date()
            do {
                let result = try await client.edit(text: sample, style: .natural, vocabulary: [], settings: snapshot, key: Secrets.read("cleanup"))
                endpointTrials["writing"] = EndpointTrial(passed: true, text: Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)).locale(lang.locale)) + " s · " + result)
            } catch { endpointTrials["writing"] = EndpointTrial(passed: false, text: error.localizedDescription) }
        }
    }
    /// Sends a sentence spoken by the Mac's own voice to the speech server, and shows what it heard.
    func trySpeechEndpoint() {
        let snapshot = settings, italian = lang.isItalian
        endpointTrials["speech"] = EndpointTrial(running: true)
        Task {
            let start = Date()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("verb-try-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try await SpeechSample.write(italian ? "Ci vediamo domani alle tre." : "See you tomorrow at three.", language: italian ? "it-IT" : "en-GB", to: url)
                let result = try await client.transcribe(url: url, settings: snapshot, key: Secrets.read("speech"), vocabulary: [])
                endpointTrials["speech"] = EndpointTrial(passed: true, text: Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)).locale(lang.locale)) + " s · " + "“" + result.text + "”")
            } catch { endpointTrials["speech"] = EndpointTrial(passed: false, text: error.localizedDescription) }
        }
    }
}

/// A sentence spoken by the Mac's own voice into a file, to try a speech server with.
@MainActor enum SpeechSample {
    static func write(_ text: String, language: String, to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        let sink = Sink(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sink.done = { continuation.resume(with: $0) }
            synthesizer.write(utterance) { buffer in sink.take(buffer) }
        }
        withExtendedLifetime(synthesizer) {}
    }
    /// Takes the voice's buffers as they come, and says once when the last has.
    private final class Sink: @unchecked Sendable {
        let url: URL
        var file: AVAudioFile?
        var done: ((Result<Void, Error>) -> Void)?
        init(url: URL) { self.url = url }
        func take(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finish(.success(())); return }
            do {
                if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
                try file?.write(from: pcm)
            } catch { finish(.failure(error)) }
        }
        private func finish(_ result: Result<Void, Error>) {
            file = nil
            done?(result); done = nil
        }
    }
}
