import AVFoundation
import SwiftUI
import VerbCore
import VerbEngine

/// Tries one microphone at a time for a few seconds while you say a sentence, and says whether
/// it hears you well enough to dictate. Nothing is recorded: only the loudness of each 20 ms is
/// kept, until the verdict.
@MainActor final class MicrophoneTester: ObservableObject {
    struct Result: Equatable {
        let verdict: MicrophoneVerdict
        let voice: Double, room: Double
        /// Seconds from opening the device to its first sound.
        let startup: Double
        /// Why the device couldn't be opened, or went away during the test.
        var failure: String? = nil
    }
    static let seconds = 4
    @Published private(set) var testing: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var remaining = 0
    @Published var results: [String: Result] = [:]
    private var input: MicrophoneInput?
    private var task: Task<Void, Never>?

    init(results: [String: Result] = [:], testing: String? = nil, level: Float = 0) {
        self.results = results; self.testing = testing; self.level = level; remaining = testing == nil ? 0 : Self.seconds - 1
    }

    func test(_ device: MicrophoneDevice) {
        stop()
        results[device.id] = nil; testing = device.id; remaining = Self.seconds
        let meter = Meter(), opened = Date()
        do {
            let input = try MicrophoneInput(device) { buffer in meter.add(buffer) }
            input.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.finish(device.id, meter, opened, failure: "The microphone went away during the test.") } }
            try input.start()
            self.input = input
        } catch {
            results[device.id] = Result(verdict: .silent, voice: -120, room: -120, startup: 0, failure: error.localizedDescription)
            testing = nil; return
        }
        task = Task { [weak self] in
            let end = Date().addingTimeInterval(Double(Self.seconds))
            while Date() < end, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                self.level = meter.latest
                self.remaining = max(1, Int(end.timeIntervalSinceNow.rounded(.up)))
            }
            guard !Task.isCancelled else { return }
            self?.finish(device.id, meter, opened, failure: nil)
        }
    }
    func stop() {
        input?.stop(); input = nil; task?.cancel(); task = nil
        testing = nil; level = 0
    }
    private func finish(_ id: String, _ meter: Meter, _ opened: Date, failure: String?) {
        guard testing == id else { return }
        stop()
        let heard = meter.heard, assessed = MicrophoneVerdict.assess(levels: heard.levels)
        results[id] = Result(verdict: assessed.verdict, voice: assessed.voice, room: assessed.room,
                             startup: heard.first.map { $0.timeIntervalSince(opened) } ?? 0, failure: failure)
    }

    /// The loudness of each 20 ms, on the audio thread; the loudest channel, where the voice is.
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [Float] = [], first: Date?
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += channels[channel][index] * channels[channel][index] }
                loudest = max(loudest, (sum / Float(buffer.frameLength)).squareRoot())
            }
            lock.lock(); levels.append(loudest); if first == nil { first = Date() }; lock.unlock()
        }
        /// The last moment, from a whisper to a raised voice, from 0 to 1.
        var latest: Float {
            lock.lock(); defer { lock.unlock() }
            guard let last = levels.last else { return 0 }
            return min(1, max(0, (20 * log10(max(last, 0.00001)) + 55) / 50))
        }
        var heard: (levels: [Float], first: Date?) { lock.lock(); defer { lock.unlock() }; return (levels, first) }
    }
}

/// "Test the microphones": each one someone speaks into, a sentence, and what it heard.
struct MicrophoneTestSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var t
    @StateObject private var tester: MicrophoneTester
    init() { _tester = StateObject(wrappedValue: MicrophoneTester()) }
    /// With results already in, for snapshots.
    init(tester: MicrophoneTester) { _tester = StateObject(wrappedValue: tester) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(t("Test the microphones", "Prova i microfoni"))
                .font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
            Text(t("Press Test and say a sentence, as when you dictate. Nothing is recorded.", "Premi Prova e di’ una frase, come quando detti. Non viene registrato nulla."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            RowList {
                ForEach(Array(model.microphones.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Hairline() }
                    row(device)
                }
            }
            if model.busy {
                StatusLabel(text: t("Finish the dictation to test.", "Termina la dettatura per provare."), symbol: "mic", tone: .neutral)
            }
            HStack {
                Spacer()
                Button(t("Done", "Fine")) { tester.stop(); dismiss() }.buttonStyle(VerbButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 600)
        .background(Palette.surfacePage)
        .onDisappear { tester.stop() }
    }

    private func row(_ device: MicrophoneDevice) -> some View {
        let chosen = model.settings.microphoneID == device.id
        let automatic = model.settings.microphoneID.isEmpty && model.automaticMicrophone?.id == device.id
        return HStack(alignment: .center, spacing: Space.md) {
            Image(systemName: Self.symbol(device.kind)).font(.system(size: 15)).foregroundStyle(Palette.textSecondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name.isEmpty ? t("Microphone", "Microfono") : device.name).font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary)
                Text(Self.kind(device.kind, t) + (chosen ? " · " + t("in use", "in uso") : automatic ? " · " + t("in use, chosen automatically", "in uso, scelto in automatico") : ""))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                if tester.testing == device.id {
                    HStack(spacing: Space.sm) {
                        LevelBar(level: tester.level).frame(width: 140, height: 6)
                        Text(t("Speak now · \(tester.remaining)", "Parla ora · \(tester.remaining)")).font(Typeface.text(TypeSize.footnote, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                } else if let result = tester.results[device.id] {
                    let verdict = Self.verdict(result, t)
                    StatusLabel(text: verdict.text, symbol: verdict.symbol, tone: verdict.tone).padding(.top, 2)
                }
            }
            Spacer(minLength: Space.sm)
            Button(tester.testing == device.id ? t("Stop", "Ferma") : t("Test", "Prova")) {
                if tester.testing == device.id { tester.stop() } else { tester.test(device) }
            }
            .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            .disabled(model.busy || (tester.testing != nil && tester.testing != device.id))
            Button(t("Use", "Usa")) { model.settings.microphoneID = device.id }
                .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true)).disabled(chosen)
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
    }

    static func symbol(_ kind: MicrophoneChoice.Kind?) -> String {
        switch kind {
        case .wired: return "cable.connector"
        case .headset: return "headphones"
        case .builtIn: return "laptopcomputer"
        case .phone: return "iphone"
        case nil: return "waveform"
        }
    }
    static func kind(_ kind: MicrophoneChoice.Kind?, _ t: Lang) -> String {
        switch kind {
        case .wired: return t("Wired or USB", "Con filo o USB")
        case .headset: return t("Bluetooth headphones", "Cuffie Bluetooth")
        case .builtIn: return t("This Mac", "Questo Mac")
        case .phone: return t("iPhone", "iPhone")
        case nil: return t("Virtual device", "Dispositivo virtuale")
        }
    }
    static func verdict(_ result: MicrophoneTester.Result, _ t: Lang) -> (text: String, symbol: String, tone: StatusLabel.Tone) {
        if let failure = result.failure { return (t.message(failure), "exclamationmark.triangle", .danger) }
        let gap = Int((result.voice - result.room).rounded())
        let slow = result.startup >= 1 ? t(" · took \(result.startup.formatted(.number.precision(.fractionLength(1)).locale(t.locale))) s to open",
                                           " · ci ha messo \(result.startup.formatted(.number.precision(.fractionLength(1)).locale(t.locale))) s ad aprirsi") : ""
        switch result.verdict {
        case .clear: return (t("Hears you clearly: your voice is \(gap) dB above the room", "Ti sente bene: la voce è \(gap) dB sopra l’ambiente") + slow, "checkmark.circle", .success)
        case .noisy: return (t("Hears you, with some noise: \(gap) dB above the room", "Ti sente, con un po’ di rumore: \(gap) dB sopra l’ambiente") + slow, "checkmark.circle", .neutral)
        case .tooNoisy: return (t("Too much noise: the room is almost as loud as you", "Troppo rumore: l’ambiente è forte quasi quanto te") + slow, "exclamationmark.triangle", .warning)
        case .faint: return (t("Hears you faintly: move closer", "Ti sente appena: avvicinati") + slow, "exclamationmark.triangle", .warning)
        case .noVoice: return (t("No voice heard: try again, saying a sentence", "Nessuna voce: riprova dicendo una frase") + slow, "questionmark.circle", .warning)
        case .silent: return (t("No sound came through: check that it isn’t muted", "Non arriva alcun suono: controlla che non sia silenziato"), "speaker.slash", .danger)
        }
    }
}

/// How loud the microphone is right now, as a filling bar.
struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceSunken)
                Capsule().fill(Palette.accent).frame(width: max(6, geometry.size.width * CGFloat(level)))
            }
        }
        .accessibilityHidden(true)
    }
}
