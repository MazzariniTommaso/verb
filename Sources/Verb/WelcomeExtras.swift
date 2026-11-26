import AppKit
import SwiftUI
import VerbCore
import VerbEngine

/// In the welcome, once the microphone is allowed: a few seconds of speech, and whether the
/// microphone Verb would use hears you well.
struct MicrophoneCheckRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @StateObject private var tester = MicrophoneTester()
    private var device: MicrophoneDevice? { model.microphones.first { $0.id == model.settings.microphoneID } ?? model.automaticMicrophone }
    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "waveform").font(.system(size: 17, weight: .regular)).foregroundStyle(Palette.textSecondary).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(t("Test the microphone", "Prova il microfono")).font(Typeface.text(TypeSize.callout, .semibold)).foregroundStyle(Palette.textPrimary)
                Text(device.map { t("Say a sentence into \($0.name) while the bar moves.", "Di’ una frase a \($0.name) mentre la barra si muove.") } ?? t("No microphone is connected.", "Nessun microfono collegato."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let device, tester.testing == device.id {
                    HStack(spacing: Space.sm) {
                        LevelBar(level: tester.level).frame(height: 8)
                        Text("\(tester.remaining) s").font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                    }
                } else if let device, let result = tester.results[device.id] {
                    let verdict = MicrophoneTestSheet.verdict(result, t)
                    StatusLabel(text: verdict.text, symbol: verdict.symbol, tone: verdict.tone)
                }
                if model.microphones.count > 1 {
                    VerbPicker(title: t("Microphone", "Microfono"), selection: $model.settings.microphoneID,
                               options: [("", t("Automatic", "Automatico"))] + model.microphones.map { ($0.id, $0.name.isEmpty ? t("Microphone", "Microfono") : $0.name) })
                        .frame(width: 240)
                }
            }
            Spacer(minLength: Space.sm)
            Button(tester.testing != nil ? t("Listening…", "Ascolto…") : t("Test", "Prova")) { if let device { tester.test(device) } }
                .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(device == nil || tester.testing != nil || !model.runsServices)
        }
        .padding(.vertical, Space.md)
        .onAppear { if model.runsServices { model.refreshMicrophones() } }
        .onDisappear { tester.stop() }
    }
}

/// How fast you type, measured on one sentence, against how fast you speak: what dictating saves.
struct SpeedTest: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var typed = ""
    @State private var started: Date?
    @State private var result: Double?
    private var sentence: String { t("The meeting moved to Thursday at four, so send the slides to Marco before lunch.", "La riunione è spostata a giovedì alle quattro, quindi manda le slide a Marco prima di pranzo.") }
    /// Your voice: the welcome's dictations once there are enough of them, else a usual pace.
    private var speaking: (wpm: Double, measured: Bool) {
        if let wpm = model.stats.wordsPerMinute { return (wpm, true) }
        if let record = model.history.first(where: { $0.mode == .dictation && $0.status == .completed }), let wpm = Speed.speaking(words: record.wordCount, seconds: record.voiced ?? record.duration) { return (wpm, true) }
        return (130, false)
    }
    var body: some View {
        Card(lifted: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                Rubric(text: t("Your speed", "La tua velocità"))
                if let typing = result ?? model.settings.coachingState.typingSpeed {
                    let voice = speaking, times = voice.wpm / max(typing, 1), hours = Speed.hoursSaved(typing: typing, speaking: voice.wpm)
                    Text(t("\(times.formatted(.number.precision(.fractionLength(1)).locale(t.locale)))× faster by voice", "\(times.formatted(.number.precision(.fractionLength(1)).locale(t.locale)))× più veloce a voce"))
                        .font(Typeface.display(TypeSize.title2, .medium)).foregroundStyle(Palette.textPrimary)
                    Text(t("You type \(Int(typing.rounded())) words a minute and speak \(Int(voice.wpm.rounded()))\(voice.measured ? "" : ", as most people do").",
                           "Scrivi \(Int(typing.rounded())) parole al minuto e ne dici \(Int(voice.wpm.rounded()))\(voice.measured ? "" : ", come la maggior parte delle persone")."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if hours >= 0.5 {
                        Text(t("About \(Int(hours.rounded())) hours a week saved, if you write half of a six-hour day.", "Circa \(Int(hours.rounded())) ore a settimana risparmiate, se scrivi metà di una giornata di sei ore."))
                            .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(t("Measure again", "Misura di nuovo")) { typed = ""; started = nil; result = nil; model.settings.coachingState.typingSpeed = nil }.buttonStyle(VerbButtonStyle(kind: .link, compact: true))
                } else {
                    Text(t("Type this sentence, then press Return:", "Scrivi questa frase, poi premi Invio:")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                    Text(sentence).font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                    TextField(t("Type it here", "Scrivila qui"), text: $typed, prompt: Text(t("Type it here", "Scrivila qui")).foregroundColor(Palette.textTertiary))
                        .textFieldStyle(.plain).font(Typeface.text(TypeSize.body)).padding(.horizontal, Space.md).frame(minHeight: 36)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderStrong.opacity(0.6)))
                        .onChange(of: typed) { _, value in if started == nil, !value.isEmpty { started = Date() } }
                        .onSubmit(measure)
                }
            }
        }
    }
    private func measure() {
        guard let started, let wpm = Speed.typing(typed, seconds: Date().timeIntervalSince(started)) else { return }
        result = wpm
        model.settings.coachingState.typingSpeed = wpm
    }
}

/// The last page's way out: an app to try the first dictation in, with Verb beside you.
struct TryInAnApp: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let finish: () -> Void
    var body: some View {
        Card(lifted: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                Rubric(text: t("Try it in an app", "Provalo in un’app"))
                Text(t("Verb opens it and shows you where to click and when to speak.", "Verb la apre e ti mostra dove cliccare e quando parlare."))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                FlowRow(spacing: Space.sm) {
                    ForEach(model.coachApps.prefix(5), id: \.bundleID) { app in
                        Button {
                            finish()
                            model.startCoach(app.bundleID)
                        } label: {
                            HStack(spacing: Space.xs) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16) }
                                Text(app.name)
                            }
                        }
                        .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    }
                }
            }
        }
    }
}

/// Views in rows that wrap to the width they are given.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
