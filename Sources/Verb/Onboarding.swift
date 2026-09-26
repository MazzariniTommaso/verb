import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import VerbCore

// The welcome: five pages that open in the window at the first launch, and again from the Help
// menu or Settings. It asks for the two permissions, gets the models, lets you try the three
// gestures on a practice sheet, and ends with the keys and where Verb lives. Every page can be
// passed over; what is still missing stays in Home's First steps.

/// The welcome's pages, in order.
enum WelcomeStep: Int, CaseIterable, Identifiable {
    case hello, permissions, models, practice, ready
    var id: Int { rawValue }
    func title(_ t: Lang) -> String {
        switch self {
        case .hello: return t("Welcome", "Inizio")
        case .permissions: return t("Permissions", "Autorizzazioni")
        case .models: return t("Models", "Modelli")
        case .practice: return t("Try it", "Prova")
        case .ready: return t("Ready", "Pronto")
        }
    }
    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }
}

/// The three gestures tried on the practice sheet.
enum PracticeGesture: Int, CaseIterable, Hashable { case hold, handsFree, edit }

extension AppModel {
    /// Opens the welcome at its first page.
    func startWelcome() {
        tourStop = nil
        welcome = .hello
        showWindow?()
    }
    /// The welcome is done, or passed over: it won't open by itself again.
    func finishWelcome(tour: Bool) {
        if !settings.onboardingComplete { settings.onboardingComplete = true }
        welcome = nil
        page = .home
        if tour { startTour(afterWelcome: true) }
    }
    /// The dictation keys as written in the interface, or fn when there are none.
    func dictationKeys(_ t: Lang) -> String { settings.keyOptions.dictation.map { t.inlineKeys($0.label) } ?? "fn" }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let step: WelcomeStep
    /// The practice sheet and the gestures tried on it, kept while you move between pages.
    @State private var sheet: String
    @State private var tried: Set<PracticeGesture>
    @State private var heldText: String?
    /// The gestures ticked on the practice sheet, for the welcome check.
    static var ticked: Set<PracticeGesture> = []
    init(step: WelcomeStep, sheet: String = "", tried: Set<PracticeGesture> = []) {
        self.step = step
        _sheet = State(initialValue: sheet)
        _tried = State(initialValue: tried)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let notice = model.notice {
                            NoticeBanner(text: t.message(notice), dismissLabel: t("Dismiss", "Chiudi")) { model.notice = nil }
                        }
                        page
                    }
                    // One frame for every page, the narrower ones set against its left edge, and the
                    // title always at the same height: the first page alone stands in the middle.
                    .frame(maxWidth: columnWidth, alignment: .leading)
                    .frame(maxWidth: step == .hello ? columnWidth : Sizing.contentMax, alignment: .leading)
                    .padding(.horizontal, Space.page)
                    .padding(.top, step == .hello ? Space.xl : Space.xxl)
                    .padding(.bottom, Space.xl)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: step == .hello ? .center : .top)
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 28)), removal: .opacity))
            if step != .hello { footer }
        }
        .background(Palette.surfacePage)
        // VoiceOver hears where the welcome is now.
        .onChange(of: step) { _, now in AccessibilityNotification.Announcement(now.title(t)).post() }
        .onChange(of: model.sheetWriting) { _, writing in
            guard step == .practice, let writing else { return }
            let gesture: PracticeGesture = writing.mode == .command ? .edit : writing.handsFree ? .handsFree : .hold
            if gesture == .hold, heldText == nil { heldText = writing.text }
            withAnimation(.easeOut(duration: Motion.base)) { _ = tried.insert(gesture) }
            Self.ticked = tried.union([gesture])
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .hello: HelloPage { go(to: .permissions) }
        case .permissions: PermissionsPage()
        case .models: ModelsPage()
        case .practice: PracticePage(sheet: $sheet, tried: tried, heldText: heldText, showModels: { go(to: .models) })
        case .ready: ReadyPage()
        }
    }

    private var columnWidth: CGFloat {
        switch step {
        case .hello: return 860
        case .practice, .ready: return Sizing.contentMax
        default: return 640
        }
    }
    /// The page's own next step carries the one primary button while it is still to do; Continue waits as a secondary one.
    private var pageHasAction: Bool {
        switch step {
        case .permissions: return !model.microphoneGranted || !model.accessibilityGranted
        case .models: return model.settings.speechProvider == .onDevice && !model.speechInstalled && !model.downloadingSpeech
        // Until a gesture has worked, trying it is the page's action.
        case .practice: return tried.isEmpty
        default: return false
        }
    }

    /// A page left behind is ticked only when what it asked for is in place.
    private func isDone(_ step: WelcomeStep) -> Bool {
        switch step {
        case .hello: return true
        case .permissions: return model.microphoneGranted && model.accessibilityGranted
        case .models: return model.settings.speechProvider == .endpoint || model.speechInstalled
        case .practice: return !tried.isEmpty
        case .ready: return false
        }
    }

    private func go(to next: WelcomeStep) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.slow)) { model.welcome = next }
    }
    private func finish(tour: Bool) {
        withAnimation(.easeOut(duration: Motion.slow)) { model.finishWelcome(tour: tour) }
    }

    /// The pages ahead, and a way out; the language on the first page.
    private var bar: some View {
        ZStack {
            if step != .hello { StepTrail(current: step, isDone: isDone) }
            HStack {
                Spacer()
                if step == .hello {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
                        Segmented(title: t("Language", "Lingua"), values: InterfaceLanguage.allCases, selection: $model.settings.interfaceOptions.language, label: { $0.nativeName })
                            .fixedSize()
                    }
                } else if step != .ready {
                    Button(t("Skip the welcome", "Salta l’introduzione")) { finish(tour: false) }
                        .buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                        .help(t("Home keeps what is still to set up.", "La Home tiene ciò che resta da configurare."))
                }
            }
        }
        .padding(.trailing, Space.lg)
        .frame(height: 60)
    }

    private var footer: some View {
        HStack(spacing: Space.sm) {
            if let previous = step.previous {
                Button(t("Back", "Indietro")) { go(to: previous) }.buttonStyle(VerbButtonStyle(kind: .quiet))
            }
            Spacer()
            if step == .ready {
                Button(t("Take the tour", "Fai il tour")) { finish(tour: true) }.buttonStyle(VerbButtonStyle(kind: .secondary))
                Button(t("Go to Home", "Vai alla Home")) { finish(tour: false) }.buttonStyle(VerbButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            } else if let next = step.next {
                let button = Button(t("Continue", "Continua")) { go(to: next) }.buttonStyle(VerbButtonStyle(kind: pageHasAction ? .secondary : .primary))
                // On the practice sheet Return writes a new line.
                if step == .practice || pageHasAction { button } else { button.keyboardShortcut(.defaultAction) }
            }
        }
        .frame(maxWidth: Sizing.contentMax)
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.base)
        .frame(maxWidth: .infinity)
    }
}

/// The pages after the first, numbered in red italic like the First steps on Home.
private struct StepTrail: View {
    let current: WelcomeStep
    let isDone: (WelcomeStep) -> Bool
    @Environment(\.lang) private var t
    private var steps: [WelcomeStep] { WelcomeStep.allCases.filter { $0 != .hello } }
    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle().fill(step.rawValue <= current.rawValue ? Palette.borderStrong.opacity(0.5) : Palette.borderSubtle).frame(width: 20, height: 1)
                }
                HStack(spacing: 6) {
                    Group {
                        if step.rawValue < current.rawValue, isDone(step) { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.textSecondary) }
                        else { Text("\(index + 1)").font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(step == current ? Palette.accent : step.rawValue < current.rawValue ? Palette.textSecondary : Palette.textTertiary) }
                    }
                    .frame(width: 14)
                    Text(step.title(t)).font(Typeface.text(TypeSize.footnote, step == current ? .semibold : .medium))
                        .foregroundStyle(step == current ? Palette.textPrimary : step.rawValue < current.rawValue ? Palette.textSecondary : Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("Step \(current.rawValue) of \(steps.count): \(current.title(t))", "Passo \(current.rawValue) di \(steps.count): \(current.title(t))"))
    }
}

/// A page's title and what it is for, then its content.
private struct StepPage<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(title).font(Typeface.display(TypeSize.title1)).tracking(Tracking.display).foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(detail).font(Typeface.text(TypeSize.callout)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.callout, Leading.ui))
                    .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - First page

private struct HelloPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let begin: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: Space.xxxl) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm + 2) {
                    VerbMark().fill(Palette.accent).frame(width: 36, height: 27)
                    Text("Verb").font(Typeface.display(TypeSize.title2, .medium)).tracking(-0.4).foregroundStyle(Palette.textPrimary)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Verb")
                .padding(.bottom, Space.xxl)
                Rubric(text: t("Two minutes to set up", "Due minuti per cominciare")).padding(.bottom, Space.md)
                Text(t("Speak, and it’s written.", "Parla, e resta scritto."))
                    .font(Typeface.display(TypeSize.hero)).tracking(Tracking.display).foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                let keys = model.dictationKeys(t), here = model.settings.speechProvider == .onDevice
                Text(t("Hold \(keys) and talk. Verb writes what you say wherever your cursor is: in Mail, in Slack, in your editor. It hears Italian and English\(here ? ", on this Mac" : "").",
                       "Tieni premuto \(keys) e parla. Verb scrive ciò che dici dove si trova il cursore: in Mail, in Slack, nel tuo editor. Capisce italiano e inglese\(here ? ", su questo Mac" : "")."))
                    .font(Typeface.text(TypeSize.callout)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.callout, Leading.reading))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.lg)
                HStack(spacing: Space.md) {
                    Button(t("Set up Verb", "Configura Verb"), action: begin).buttonStyle(VerbButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    Text(t("Permissions, models, a first try.", "Autorizzazioni, modelli, una prima prova.")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textTertiary)
                }
                .padding(.top, Space.xxl)
            }
            .frame(minWidth: 300, maxWidth: 380, alignment: .leading)
            SpeakingDemo().frame(minWidth: 330, maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Verb at work, on a loop: you speak into Mail, the words form above the overlay, and the tidy
/// sentence lands where the cursor was. With Reduce Motion it holds the last moment.
private struct SpeakingDemo: View {
    @Environment(\.lang) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var voice = DemoVoice()
    var body: some View {
        let moment = reduceMotion ? DemoVoice.Moment.written : voice.moment
        let spoken = t("Let’s meet on Tuesday, actually Wednesday, at three", "Ci vediamo martedì, anzi mercoledì, alle tre")
        let written = t("Let’s meet on Wednesday at three.", "Ci vediamo mercoledì alle tre.")
        VStack(spacing: Space.xl) {
            mail(written: moment == .written ? written : nil)
            VStack(spacing: -Space.xs) {
                words(spoken, moment: moment)
                pill(moment)
            }
            .frame(height: 118, alignment: .bottom)
            .animation(DemoVoice.frozen == nil ? .easeOut(duration: Motion.base) : nil, value: moment.isSpeaking)
        }
        .onAppear { if !reduceMotion { voice.run() } }
        .onDisappear { voice.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("An example: you say “\(spoken)”, and Verb writes “\(written)” in Mail.", "Un esempio: dici “\(spoken)”, e Verb scrive “\(written)” in Mail."))
    }

    private func mail(written: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.fillPressed).frame(width: 9, height: 9) }
                Spacer()
                Text(t("New message", "Nuovo messaggio")).font(Typeface.text(TypeSize.caption, .medium)).foregroundStyle(Palette.textTertiary)
                Spacer()
                Color.clear.frame(width: 39, height: 9)
            }
            .padding(.horizontal, Space.md).frame(height: 32)
            Hairline()
            field(t("To:", "A:"), "Giulia")
            Hairline()
            field(t("Subject:", "Oggetto:"), t("Wednesday", "Mercoledì"))
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if let written { Text(written).foregroundStyle(Palette.textPrimary).transition(.opacity) }
                Caret()
            }
            .font(Typeface.display(TypeSize.reading))
            .padding(.horizontal, Space.base).padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .animation(.easeOut(duration: Motion.slow), value: written)
        }
        .raisedSheet(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous), shadow: Palette.shadow.opacity(0.35), radius: 14, y: 6)
    }
    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(label).foregroundStyle(Palette.textTertiary)
            Text(value).foregroundStyle(Palette.textPrimary)
        }
        .font(Typeface.text(TypeSize.footnote))
        .padding(.horizontal, Space.base).frame(height: 30)
    }

    /// The words as they are heard: settled in ink, the last two lighter, as over the real overlay.
    @ViewBuilder private func words(_ spoken: String, moment: DemoVoice.Moment) -> some View {
        if case .speaking(let progress) = moment {
            let all = spoken.split(separator: " ").map(String.init)
            let shown = min(all.count, Int((progress * Double(all.count)).rounded(.up)))
            let settled = all.prefix(max(0, shown - 2)).joined(separator: " "), tentative = all.prefix(shown).suffix(min(2, shown)).joined(separator: " ")
            (Text(settled + (settled.isEmpty ? "" : " ")).foregroundColor(Palette.textPrimary) + Text(tentative).foregroundColor(Palette.textTertiary))
                .font(Typeface.display(TypeSize.callout))
                .lineLimit(2).multilineTextAlignment(.leading)
                .padding(.horizontal, Space.base).padding(.vertical, Space.md)
                .frame(width: 300, alignment: .leading)
                .raisedSheet(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous), shadow: Palette.shadow.opacity(0.3), radius: 10, y: 3)
                .padding(.bottom, Space.sm)
                .transition(.opacity)
        }
    }

    private func pill(_ moment: DemoVoice.Moment) -> some View {
        HStack(spacing: Space.md) {
            switch moment {
            case .waiting, .speaking:
                LiveDot(meter: voice.meter, size: 18)
                InkStroke(meter: voice.meter, active: !reduceMotion, still: reduceMotion).frame(width: 118, height: 26)
            case .tidying:
                InkDrops(width: 24, height: 14)
                ShimmerText(text: t("Tidying up", "Metto in bella"), font: Typeface.display(TypeSize.callout).italic(), shimmer: !reduceMotion)
            case .written:
                OutcomeIcon(outcome: .delivered)
                Text(t("Pasted into Mail", "Incollato in Mail")).font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, Space.base)
        .frame(height: 44)
        .raisedSheet(Capsule(), shadow: Palette.shadow.opacity(0.4), radius: 12, y: 4)
        .opacity(moment == .waiting ? 0 : 1)
        .animation(DemoVoice.frozen == nil ? .easeOut(duration: Motion.base) : nil, value: moment == .waiting)
    }
}

/// The cursor in the demo's message, blinking like a real one.
private struct Caret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { timeline in
            let on = reduceMotion || DemoVoice.frozen != nil || Int(timeline.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle().fill(Palette.accent).frame(width: 2, height: 19).opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// The clock of the demo: a made-up voice for the ink, and the moment of the loop.
@MainActor final class DemoVoice: ObservableObject {
    enum Moment: Equatable {
        case waiting, speaking(Double), tidying, written
        var isSpeaking: Bool { if case .speaking = self { return true }; return false }
    }
    @Published private(set) var moment: Moment = .waiting
    let meter = LevelMeter()
    private var timer: Timer?
    private var started = Date()
    static let loop = 9.0, speechStart = 0.8, speechEnd = 4.4, tidyEnd = 5.3
    /// A moment of the loop to hold instead of the clock, for snapshots.
    static var frozen: Double?

    func run() {
        if let frozen = Self.frozen {
            meter.preview((0..<400).map { Self.level(at: Self.speechStart + Double($0) * LevelMeter.step) })
            moment = Self.moment(at: frozen)
            return
        }
        guard timer == nil else { return }
        started = Date()
        // Like the microphone, a tenth of a second of levels at a time.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let time = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: Self.loop)
        meter.push((0..<10).map { Self.level(at: time - 0.1 + Double($0) * LevelMeter.step) }, at: Date().timeIntervalSinceReferenceDate)
        let next = Self.moment(at: time)
        if next != moment { moment = next }
    }
    /// Syllables and short breaths while the demo speaks; silence around it.
    private static func level(at time: Double) -> Float {
        guard time >= speechStart, time < speechEnd else { return 0 }
        let x = time - speechStart
        let syllables = max(0, sin(x * 11) * 0.5 + 0.5) * max(0, sin(x * 1.9 + 0.4))
        return Float(min(1, 0.12 + 0.55 * syllables + 0.08 * sin(x * 29)))
    }
    private static func moment(at time: Double) -> Moment {
        if time < speechStart { return .waiting }
        if time < speechEnd { return .speaking(((time - speechStart) / (speechEnd - speechStart) * 20).rounded() / 20) }
        return time < tidyEnd ? .tidying : .written
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var askedAccessibility = false
    var body: some View {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micRefused = micStatus == .denied || micStatus == .restricted
        StepPage(title: t("Two permissions, once", "Due autorizzazioni, una volta sola"),
                 detail: t("macOS asks you for both. Verb uses them to hear you while you dictate and to write where your cursor is.",
                           "macOS te le chiede entrambe. Verb le usa per sentirti mentre detti e per scrivere dove si trova il cursore.")) {
            Card(lifted: true) {
                PermissionRow(symbol: "mic", title: t("Microphone", "Microfono"), granted: model.microphoneGranted, allowed: t("Allowed", "Consentito"),
                              detail: micRefused && !model.microphoneGranted
                                ? t("Microphone access is off for Verb. Turn it on in System Settings, then come back.", "L’accesso al microfono è spento per Verb. Attivalo in Impostazioni di Sistema, poi torna qui.")
                                : t("Verb listens only while you dictate or record a meeting, and for “Hey \(model.settings.voiceOptions.spokenName)” if you turn it on.", "Verb ascolta solo mentre detti o registri una riunione e, se lo attivi, per sentire “Ehi \(model.settings.voiceOptions.spokenName)”.")) {
                    if micRefused {
                        Button(t("Open System Settings", "Apri Impostazioni di Sistema")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                            .buttonStyle(VerbButtonStyle(kind: .primary, compact: true))
                    } else {
                        Button(t("Allow the microphone", "Consenti il microfono")) { model.requestMicrophone() }
                            .buttonStyle(VerbButtonStyle(kind: .primary, compact: true))
                    }
                }
                Hairline()
                PermissionRow(symbol: "keyboard", title: t("Accessibility", "Accessibilità"), granted: model.accessibilityGranted, allowed: t("Allowed", "Consentita"),
                              detail: t("Lets \(model.dictationKeys(t)) start dictation in any app, and lets Verb type where your cursor is.", "Permette a \(model.dictationKeys(t)) di avviare la dettatura in qualsiasi app e a Verb di scrivere dove si trova il cursore.")) {
                    Button(askedAccessibility ? t("Open again", "Riapri") : t("Open System Settings", "Apri Impostazioni di Sistema")) { askedAccessibility = true; model.requestAccessibility() }
                        .buttonStyle(VerbButtonStyle(kind: model.microphoneGranted && !askedAccessibility ? .primary : .secondary, compact: true))
                }
                if askedAccessibility && !model.accessibilityGranted {
                    HStack(alignment: .top, spacing: Space.md) {
                        InkSpinner(size: 14).padding(.top, 2)
                        Text(t("Switch on Verb in the list that opened. Verb notices by itself and comes back here. If Verb is already on, switch it off and on again.",
                               "Attiva Verb nell’elenco che si è aperto. Verb se ne accorge da solo e torna qui. Se Verb è già attivo, spegnilo e riaccendilo."))
                            .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fillHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .padding(.leading, 52).padding(.bottom, Space.sm)
                    .transition(.opacity)
                }
            }
            Label {
                Text(t("Verb takes no screenshots. Your voice stays on this Mac unless you choose a server in Models.", "Verb non cattura lo schermo. La tua voce resta su questo Mac, a meno che tu non scelga un server in Modelli."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "lock") }
                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
        }
        .animation(.easeOut(duration: Motion.base), value: askedAccessibility)
        // macOS says nothing when a permission changes: Verb looks every second while this page is open.
        .task {
            guard model.runsServices else { return }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); model.refreshPermissions() }
        }
        .onChange(of: model.accessibilityGranted) { _, granted in
            // Back from System Settings by itself, to the next step.
            if granted, askedAccessibility, !NSApp.isActive { model.showWindow?() }
        }
    }
}

private struct PermissionRow<Action: View>: View {
    let symbol: String
    let title: String
    let granted: Bool
    /// “Allowed”, agreeing in Italian with the permission's name.
    let allowed: String
    let detail: String
    @ViewBuilder var action: Action
    @Environment(\.lang) private var t
    var body: some View {
        HStack(alignment: .center, spacing: Space.base) {
            // Ink either way: the button beside it asks, and the label says when it's done.
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(granted ? Palette.textSecondary : Palette.textPrimary)
                .frame(width: 36, height: 36).background(Palette.fillHover, in: Circle())
                .accessibilityHidden(true)
            RowLabel(title: title, detail: detail)
            if granted { StatusLabel(text: allowed, symbol: "checkmark", tone: .success).fixedSize() } else { action }
        }
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Models

private struct ModelsPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        StepPage(title: t("Where your voice becomes text", "Dove la voce diventa testo"),
                 detail: t("Recognition turns your voice into words. A writing model can tidy them up. Both can work offline, on this Mac.",
                           "Il riconoscimento trasforma la voce in parole. Un modello di scrittura può metterle in bella. Entrambi possono lavorare offline, su questo Mac.")) {
            Card(lifted: true) { speech }
            Card { writing }
        }
        .task {
            // What the local engine already holds, when Verb didn't ask at launch.
            guard model.runsServices, model.settings.cleanupProvider == .local, model.writer.available, model.writerModels.isEmpty else { return }
            try? await model.writer.start()
            if let models = try? await model.client.localModels() { model.writerModels = models }
        }
    }

    private var speech: some View {
        let local = model.settings.speechProvider == .onDevice
        let catalog = try? SpeechCatalog.model(model.settings.localModel)
        let name = catalog.map { t.engine($0.id) } ?? model.settings.localModel
        let size = catalog.map { ByteCountFormatter.string(fromByteCount: $0.downloadBytes, countStyle: .file) } ?? ""
        return VStack(alignment: .leading, spacing: Space.md) {
            Rubric(text: t("Needed to dictate", "Serve per dettare"))
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(title: t("Speech recognition", "Riconoscimento vocale"))
                Spacer()
                if !local { StatusLabel(text: t("Your server", "Il tuo server"), symbol: "network", tone: .neutral) }
                else if model.speechInstalled { StatusLabel(text: t("Ready offline", "Pronto offline"), symbol: "checkmark.circle", tone: .success) }
                else if model.downloadingSpeech { StatusLabel(text: t("Downloading", "Download in corso"), symbol: "arrow.down.circle", tone: .neutral) }
                else { StatusLabel(text: t("Needs download", "Da scaricare"), symbol: "arrow.down.circle", tone: .warning) }
            }
            .padding(.top, -Space.xs)
            Text(local
                 ? t("\(name) hears Italian and English, even in the same sentence, with no internet. Your audio never leaves the Mac.", "\(name) capisce italiano e inglese, anche nella stessa frase, senza internet. L’audio non esce mai dal Mac.")
                 : t("Recognition runs on the server you chose: \(URL(string: model.settings.speechEndpoint)?.host ?? model.settings.speechEndpoint). You can change it in Models.", "Il riconoscimento lavora sul server che hai scelto: \(URL(string: model.settings.speechEndpoint)?.host ?? model.settings.speechEndpoint). Puoi cambiarlo in Modelli."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.ui))
                .frame(maxWidth: 480, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if local && !model.speechInstalled {
                if model.downloadingSpeech { DownloadProgress() }
                else {
                    Button(t("Download the speech model · \(size)", "Scarica il modello vocale · \(size)")) { model.downloadSpeech() }
                        .buttonStyle(VerbButtonStyle(kind: .primary)).disabled(model.downloadingWriter)
                }
            }
        }
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Rubric(text: t("Optional", "Facoltativo"))
            SectionHeading(title: t("Writing model", "Modello di scrittura")).padding(.top, -Space.xs)
            Text(t("Quick rules take out fillers and stumbled repeats in every style but Verbatim. A writing model also resolves what you correct out loud (“Tuesday, actually Wednesday”), lists and long dictations, and it runs voice edits and transforms.",
                   "Le regole rapide tolgono intercalari e ripetizioni in ogni stile tranne Alla lettera. Un modello di scrittura risolve anche le correzioni dette a voce (“martedì, anzi mercoledì”), gli elenchi e le dettature lunghe, e fa funzionare modifiche a voce e trasformazioni."))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.ui))
                .frame(maxWidth: 480, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Segmented(title: t("Writing model", "Modello di scrittura"), values: CleanupProvider.allCases, selection: $model.settings.cleanupProvider, label: shortTitle)
                .padding(.top, Space.xs)
            provider
        }
    }

    /// The Models page's names for the choices, the server's shortened to fit.
    private func shortTitle(_ provider: CleanupProvider) -> String {
        switch provider {
        case .local: return t("On this Mac", "Su questo Mac")
        case .harness: return t("My subscriptions", "I miei abbonamenti")
        case .endpoint: return t("Server", "Server")
        case .off: return t("No AI cleanup", "Nessuna rifinitura AI")
        }
    }

    @ViewBuilder private var provider: some View {
        switch model.settings.cleanupProvider {
        case .local:
            if !model.writer.available {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    note(t("A private model on this Mac, run by Ollama, a free app. Install it, then come back to this page.", "Un modello privato su questo Mac, fatto girare da Ollama, un’app gratuita. Installala, poi torna a questa pagina."))
                    Spacer(minLength: Space.sm)
                    Link(destination: URL(string: "https://ollama.com/download/mac")!) { Label(t("Install Ollama", "Installa Ollama"), systemImage: "arrow.up.right") }
                        .font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.accent).fixedSize()
                }
            } else if model.writerModels.contains(model.settings.cleanupModel) {
                StatusLabel(text: t("\(Self.writerName(model.settings.cleanupModel)) is ready on this Mac, offline.", "\(Self.writerName(model.settings.cleanupModel)) è pronto su questo Mac, offline."), symbol: "checkmark.circle", tone: .success)
            } else if model.downloadingWriter {
                DownloadProgress()
            } else {
                HStack(spacing: Space.md) {
                    Button(t("Download the writing model · about 2.5 GB", "Scarica il modello di scrittura · circa 2,5 GB")) { model.downloadWriter() }
                        .buttonStyle(VerbButtonStyle(kind: .secondary)).disabled(model.downloadingSpeech)
                    note(model.downloadingSpeech ? t("After the speech model.", "Dopo il modello vocale.") : t("A private Ollama model, offline.", "Un modello Ollama privato, offline."))
                }
            }
        case .harness:
            if model.writerReady {
                StatusLabel(text: t("\(model.settings.harnessOptions.provider.title) is connected.", "\(model.settings.harnessOptions.provider.title) è collegato."), symbol: "checkmark.circle", tone: .success)
            } else {
                note(t("Claude Code, Codex, Cursor, Gemini or Copilot, with the subscription you already have. Connect it in Models after the welcome: your text reaches it only once you allow remote processing.",
                       "Claude Code, Codex, Cursor, Gemini o Copilot, con l’abbonamento che hai già. Collegalo in Modelli dopo l’introduzione: il tuo testo gli arriva solo quando consenti l’elaborazione remota."))
            }
        case .endpoint:
            note(t("A hosted or custom server: any chat completions API, yours included. Enter its address and key in Models after the welcome.", "Un server ospitato o personale: qualsiasi API chat completions, anche la tua. Inserisci indirizzo e chiave in Modelli dopo l’introduzione."))
        case .off:
            note(t("Verb writes your words as heard, with your dictionary and snippets. Voice edits and transforms need a model: you can add one in Models.",
                   "Verb scrive le parole come le ha sentite, con dizionario e frasi pronte. Modifiche a voce e trasformazioni richiedono un modello: puoi aggiungerlo in Modelli."))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    /// “Qwen3 4B” for qwen3:4b-instruct-2507-q4_K_M; other tags as they are written.
    static func writerName(_ tag: String) -> String {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, parts[0].lowercased().hasPrefix("qwen"), let size = parts[1].split(separator: "-").first, size.lowercased().hasSuffix("b") else { return tag }
        return parts[0].prefix(1).uppercased() + parts[0].dropFirst() + " " + size.uppercased()
    }
}

/// A download under way, with its share and a way to stop it.
private struct DownloadProgress: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(t.message(model.downloadStatus)).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Spacer()
                Text(model.downloadProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale))).font(Typeface.text(TypeSize.footnote)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                Button(t("Cancel", "Annulla")) { model.cancelDownload() }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
            }
            ProgressView(value: model.downloadProgress).tint(Palette.controlOn)
        }
    }
}

// MARK: - Practice

private struct PracticePage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Binding var sheet: String
    let tried: Set<PracticeGesture>
    /// What the first held dictation wrote, to say whether the correction was resolved.
    var heldText: String? = nil
    let showModels: () -> Void
    private var speechMissing: Bool { model.settings.speechProvider == .onDevice && !model.speechInstalled }
    var body: some View {
        StepPage(title: t("Now try it", "Ora prova"),
                 detail: t("Three gestures, on this sheet. They work the same in every app.", "Tre gesti, su questo foglio. Funzionano allo stesso modo in ogni app.")) {
            if speechMissing {
                blocker(model.downloadingSpeech
                        ? t("The speech model is still downloading (\(model.downloadProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale)))). You can try as soon as it’s ready.", "Il modello vocale si sta ancora scaricando (\(model.downloadProgress.formatted(.percent.precision(.fractionLength(0)).locale(t.locale)))). Puoi provare appena è pronto.")
                        : t("The speech model isn’t on this Mac yet. Download it first.", "Il modello vocale non è ancora su questo Mac. Scaricalo prima."),
                        action: model.downloadingSpeech ? nil : (t("Go to Models", "Vai ai Modelli"), showModels))
            } else if !model.accessibilityGranted {
                blocker(t("Without Accessibility, \(model.dictationKeys(t)) can’t start a dictation. Use Dictate on the sheet, or allow it now.", "Senza Accessibilità, \(model.dictationKeys(t)) non può avviare la dettatura. Usa Detta sul foglio, oppure consentila ora."),
                        action: (t("Open System Settings", "Apri Impostazioni di Sistema"), { model.requestAccessibility() }))
            }
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(PracticeGesture.allCases, id: \.self) { gesture in
                        GestureRow(gesture: gesture, done: tried.contains(gesture), current: current == gesture, written: gesture == .hold ? heldText : nil)
                    }
                }
                .frame(width: 318)
                PracticeSheet(text: $sheet, disabled: speechMissing)
                    .frame(maxWidth: .infinity, minHeight: 330)
            }
        }
    }
    /// The first gesture not tried yet.
    private var current: PracticeGesture? { PracticeGesture.allCases.first { !tried.contains($0) } }

    private func blocker(_ text: String, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .center, spacing: Space.md) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.warning).accessibilityHidden(true)
            Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action { Button(action.0, action: action.1).buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).fixedSize() }
        }
        .padding(.horizontal, Space.base).padding(.vertical, Space.sm)
        .background(Palette.warningTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.warning.opacity(0.35)))
    }
}

/// One gesture: its keys, what to do, and a word once it worked. The one to try next is a sheet
/// lifted from the page; its keys light up while Verb hears you.
private struct GestureRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let gesture: PracticeGesture
    let done: Bool
    let current: Bool
    var written: String? = nil
    var body: some View {
        let keys = model.settings.keyOptions
        HStack(alignment: .top, spacing: Space.md) {
            Group {
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.success) }
                else { Text("\(gesture.rawValue + 1)").font(Typeface.display(TypeSize.title3).italic()).foregroundStyle(current ? Palette.accent : Palette.textTertiary) }
            }
            .frame(width: 18, height: 24)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .center, spacing: Space.sm) {
                    Text(title).font(Typeface.text(TypeSize.body, .semibold)).foregroundStyle(done ? Palette.textSecondary : Palette.textPrimary)
                    Spacer(minLength: Space.xs)
                    LitKeys(parts: parts(keys), lit: active)
                }
                Text(instruction(keys)).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                if let phrase, !needsWriter {
                    Text("“" + phrase + "”").font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(Palette.textPrimary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                if done {
                    Text(result).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.success).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.md)
        .background { if current { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.surfaceRaised).shadow(color: Palette.shadow.opacity(0.3), radius: 6, y: 2) } }
        .overlay { if current { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderSubtle) } }
        .opacity(needsWriter ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private var needsWriter: Bool { gesture == .edit && (model.settings.cleanupProvider == .off || !model.writerReady) }
    /// The writing model will tidy a dictation with a correction in it.
    private var resolves: Bool { model.settings.cleanupProvider != .off && model.writerReady && model.settings.cleanupPolicy != .never }
    /// Verb is hearing this very gesture.
    private var active: Bool {
        guard model.phase == .recording || model.phase == .authorizing else { return false }
        switch gesture {
        case .hold: return model.activeMode == .dictation && !model.handsFree
        case .handsFree: return model.activeMode == .dictation && model.handsFree
        case .edit: return model.activeMode == .command
        }
    }
    private var title: String {
        switch gesture {
        case .hold: return t("Hold to dictate", "Tieni premuto e detta")
        case .handsFree: return t("Hands-free", "A mani libere")
        case .edit: return t("Edit by voice", "Modifica a voce")
        }
    }
    private func parts(_ keys: KeyBindings) -> [String] {
        switch gesture {
        case .hold: return keys.dictation?.parts.map(t.keys) ?? []
        case .handsFree: return (keys.dictation?.parts.map(t.keys) ?? []) + ["+", t.keys("Space")]
        case .edit: return keys.voiceEdit?.parts.map(t.keys) ?? []
        }
    }
    private func instruction(_ keys: KeyBindings) -> String {
        let dictate = keys.dictation.map { t.inlineKeys($0.label) }
        switch gesture {
        case .hold:
            guard let dictate else { return t("Dictation has no keys: choose them in Settings, or use Dictate on the sheet.", "La dettatura non ha tasti: sceglili nelle Impostazioni, oppure usa Detta sul foglio.") }
            return t("Hold \(dictate), say this, then let go:", "Tieni premuto \(dictate), di’ questa frase, poi lascia:")
        case .handsFree:
            guard let dictate else { return t("Dictate, on the sheet, starts a hands-free dictation. Space finishes it.", "Detta, sul foglio, avvia una dettatura a mani libere. Spazio la termina.") }
            return t("Hold \(dictate) and tap Space, then let go of both. Talk as long as you like: Space finishes, Escape cancels.", "Tieni premuto \(dictate) e tocca Spazio, poi lascia entrambi. Parla quanto vuoi: Spazio termina, Esc annulla.")
        case .edit:
            if needsWriter { return t("Needs a writing model. Once you have one in Models, try it on any text you select.", "Serve un modello di scrittura. Quando ne avrai uno in Modelli, provala su qualsiasi testo selezionato.") }
            guard let edit = keys.voiceEdit.map({ t.inlineKeys($0.label) }) else { return t("Voice edit has no keys: choose them in Settings.", "La modifica a voce non ha tasti: sceglili nelle Impostazioni.") }
            return t("Select what you wrote, hold \(edit) and say:", "Seleziona ciò che hai scritto, tieni premuto \(edit) e di’:")
        }
    }
    /// What to say aloud, set apart as the user's words are.
    private var phrase: String? {
        switch gesture {
        case .hold:
            guard model.settings.keyOptions.dictation != nil else { return nil }
            return resolves ? t("Let’s meet on Tuesday, actually Wednesday, at three.", "Ci vediamo martedì, anzi mercoledì, alle tre.")
                            : t("Let’s meet on Wednesday at three, at the office.", "Ci vediamo mercoledì alle tre, in ufficio.")
        case .handsFree: return nil
        case .edit: return model.settings.keyOptions.voiceEdit == nil ? nil : t("make it more formal", "rendilo più formale")
        }
    }
    private var result: String {
        switch gesture {
        case .hold:
            let place = t("Written where the cursor was, as it will be in any app.", "Scritto dove c’era il cursore, come sarà in ogni app.")
            // Only when Wednesday stayed and Tuesday went.
            let text = (written ?? "").lowercased()
            let resolved = resolves && !text.contains("tuesday") && !text.contains("martedì") && (text.contains("wednesday") || text.contains("mercoledì"))
            return resolved ? place + " " + t("Verb kept only the day you meant.", "Verb ha tenuto solo il giorno che intendevi.") : place
        case .handsFree: return t("For long thoughts. A cancelled dictation can be restored for a few seconds.", "Per i pensieri lunghi. Una dettatura annullata si può ripristinare per qualche secondo.")
        case .edit: return t("Any text you select, in any app, can change this way.", "Qualsiasi testo selezionato, in ogni app, può cambiare così.")
        }
    }
}

/// Keycaps that light up in red pencil while they are held.
private struct LitKeys: View {
    let parts: [String]
    let lit: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part == "+" { Text("+").font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary) }
                else {
                    Text(part).font(Typeface.text(TypeSize.caption, .medium)).foregroundStyle(lit ? Palette.accentStrong : Palette.textPrimary).lineLimit(1)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
                        .background(lit ? Palette.accentTint : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).strokeBorder(lit ? Palette.accent : Palette.borderStrong.opacity(0.55)))
                        .shadow(color: Palette.shadow.opacity(lit ? 0 : 0.5), radius: 0, y: 1)
                        .offset(y: lit ? 1 : 0)
                }
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: lit)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: " "))
    }
}

/// The sheet the gestures are tried on. With the cursor in it, a dictation or a voice edit goes
/// straight here, as in a note.
private struct PracticeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Binding var text: String
    let disabled: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Overline(text: t("Practice sheet", "Foglio di prova"))
                Spacer()
                if !text.isEmpty {
                    Button(t("Clear", "Svuota")) { text = "" }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                }
                Button { model.handsFree = true; model.begin() } label: { Label(t("Dictate", "Detta"), systemImage: "mic") }
                    .buttonStyle(VerbButtonStyle(kind: .secondary, compact: true)).disabled(model.busy || disabled)
                    .help(t("Starts a hands-free dictation on the sheet. Space finishes.", "Avvia una dettatura a mani libere sul foglio. Spazio termina."))
            }
            .padding(.leading, Space.base).padding(.trailing, Space.sm).frame(height: 44)
            Hairline()
            ZStack(alignment: .topLeading) {
                NoteTextView(text: $text, practice: true)
                if text.isEmpty {
                    Text(t("Click here, then hold \(model.dictationKeys(t)) and speak.", "Fai clic qui, poi tieni premuto \(model.dictationKeys(t)) e parla."))
                        .font(Typeface.display(TypeSize.reading).italic()).foregroundStyle(Palette.textTertiary)
                        .padding(.leading, 25).padding(.top, 18)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity)
            Hairline()
            status.padding(.horizontal, Space.base).frame(height: 40)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .raisedSheet(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous), shadow: Palette.shadow.opacity(0.45), radius: 18, y: 8)
    }

    /// What Verb is doing, as the overlay says it; otherwise what to do when fn does nothing.
    @ViewBuilder private var status: some View {
        HStack(spacing: Space.sm) {
            if model.busy {
                if model.phase == .recording { LiveDot(meter: model.meter, size: 14) }
                else if model.modelAtWork { InkDrops(width: 20, height: 12) }
                else { InkSpinner(size: 12) }
                Text(model.phaseTitle(t)).font(Typeface.display(TypeSize.footnote + 1).italic()).foregroundStyle(Palette.textPrimary)
                Spacer()
            } else {
                Text(t("\(model.dictationKeys(t)) does nothing? Some keyboards don’t send it.", "\(model.dictationKeys(t)) non fa nulla? Alcune tastiere non lo inviano."))
                    .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                Spacer()
                Button(t("Change keys", "Cambia i tasti")) { editing = KeyEditing(target: .dictation) }.buttonStyle(VerbButtonStyle(kind: .link, compact: true))
            }
        }
        .sheet(item: $editing) { KeyCaptureSheet(target: $0.target).environmentObject(model).environment(\.lang, t) }
    }
    @State private var editing: KeyEditing?
}

// MARK: - Ready

private struct ReadyPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        StepPage(title: t("Ready when you are", "Pronto quando vuoi"),
                 detail: t("Verb waits in the menu bar. Close this window with ⌘W: \(model.dictationKeys(t)) works in every app.",
                           "Verb aspetta nella barra dei menu. Chiudi questa finestra con ⌘W: \(model.dictationKeys(t)) funziona in ogni app.")) {
            HStack(alignment: .top, spacing: Space.xl) {
                Card(lifted: true) {
                    Rubric(text: t("Your keys", "I tuoi tasti")).padding(.bottom, Space.base)
                    KeyLegend()
                    Text(t("Change them in Settings → Keyboard.", "Si cambiano in Impostazioni → Tastiera."))
                        .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textTertiary).padding(.top, Space.base)
                }
                VStack(alignment: .leading, spacing: Space.lg) {
                    MenuBarSketch()
                    Card(padding: Space.lg) { OpenAtLoginSwitch() }
                }
                .frame(width: 360)
            }
        }
    }
}

/// Every command with its keys, as they are set now.
struct KeyLegend: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        let keys = model.settings.keyOptions
        Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.sm) {
            row(t("Dictate", "Detta"), t("hold, speak, let go", "tieni premuto, parla, lascia"), keys.dictation.map { $0.parts.map(t.keys) })
            row(t("Hands-free", "A mani libere"), t("then Space finishes, Escape cancels", "poi Spazio termina, Esc annulla"), keys.dictation.map { $0.parts.map(t.keys) + ["+", t.keys("Space")] })
            row(t("Voice edit", "Modifica a voce"), t("hold with text selected", "tieni premuto con un testo selezionato"), keys.voiceEdit.map { $0.parts.map(t.keys) })
            row(t("Paste the last dictation", "Incolla l’ultima dettatura"), nil, keys.pasteLast.map { $0.parts.map(t.keys) })
            row(t("Copy the last dictation", "Copia l’ultima dettatura"), nil, keys.copyLast.map { $0.parts.map(t.keys) })
            row(t("Notepad", "Blocco note"), t("over any app", "sopra qualsiasi app"), keys.notepad.map { $0.parts.map(t.keys) })
            if let first = model.library.transforms.first {
                row(t("Transform the selection", "Trasforma la selezione"), "“\(first.name)”" + (model.library.transforms.count > 1 ? t(" and the others", " e le altre") : ""), first.keys.map { $0.parts.map(t.keys) })
            }
        }
    }
    private func row(_ title: String, _ detail: String?, _ parts: [String]?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Group {
                if let parts { LitKeys(parts: parts, lit: false) }
                else { Text(t("No keys", "Nessun tasto")).font(Typeface.text(TypeSize.caption, .medium).italic()).foregroundStyle(Palette.textTertiary) }
            }
            .gridColumnAlignment(.trailing)
            (Text(title).font(Typeface.text(TypeSize.body, .medium)).foregroundColor(Palette.textPrimary)
             + Text(detail.map { "  " + $0 } ?? "").font(Typeface.text(TypeSize.footnote)).foregroundColor(Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where Verb lives once the window is closed: its mark in the menu bar, and the menu it opens.
struct MenuBarSketch: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var compact = false
    @State private var width: CGFloat = 360
    private static let menuWidth: CGFloat = 280, markWidth: CGFloat = 32
    var body: some View {
        let system: CGFloat = compact ? 96 : 150
        // The menu opens under the mark, as far as the sketch lets it.
        let mark = width - Space.md - system - Space.base - Self.markWidth
        let menuX = min(max(0, mark + Self.markWidth / 2 - Self.menuWidth / 2), max(0, width - Self.menuWidth))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.base) {
                Spacer(minLength: 0)
                VerbMark(small: true).fill(Palette.textPrimary).frame(width: 18, height: 13)
                    .frame(width: Self.markWidth, height: 22)
                    .background(Palette.fillPressed, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.accent, lineWidth: 1.5))
                HStack(spacing: Space.base) {
                    Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                    if !compact { Text(Date().formatted(.dateTime.hour().minute().locale(t.locale))).font(Typeface.text(TypeSize.footnote, .medium)) }
                }
                .frame(width: system, alignment: .trailing)
            }
            .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Space.md).frame(height: 30)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Palette.borderSubtle))
            .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, value in width = value } })
            menu.padding(.leading, menuX)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("Verb’s mark in the menu bar, with its menu open.", "Il simbolo di Verb nella barra dei menu, con il suo menu aperto."))
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader(title: t("Ready", "Pronto"), hint: model.startHint(t), live: false)
            Hairline().padding(.horizontal, Space.sm)
            item("mic", t("Start hands-free dictation", "Avvia la dettatura a mani libere"), nil)
            item("note.text", t("Notepad", "Blocco note"), model.settings.keyOptions.notepad.map { t.keys($0.label) })
            if !compact { item("person.2.wave.2", t("Record a meeting", "Registra una riunione"), nil) }
        }
        .padding(.bottom, Space.xs)
        .frame(width: Self.menuWidth)
        .raisedSheet(RoundedRectangle(cornerRadius: Radius.md, style: .continuous), shadow: Palette.shadow.opacity(0.4), radius: 12, y: 5)
    }
    private func item(_ symbol: String, _ title: String, _ keys: String?) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).frame(width: 18)
            Text(title).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textPrimary).lineLimit(1)
            Spacer(minLength: Space.sm)
            if let keys { Text(keys).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textTertiary) }
        }
        .padding(.horizontal, Space.md).frame(height: 26)
    }
}

/// Open at login, the same switch in the welcome and in Settings.
struct OpenAtLoginSwitch: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @State private var enabled = SMAppService.mainApp.status == .enabled
    var body: some View {
        SwitchRow(title: t("Open at login", "Apri al login"),
                  detail: t("Verb starts quietly in the menu bar, ready for \(model.dictationKeys(t)).", "Verb si avvia in silenzio nella barra dei menu, pronto per \(model.dictationKeys(t))."),
                  isOn: $enabled)
            .onChange(of: enabled) { _, on in
                guard on != (SMAppService.mainApp.status == .enabled) else { return }
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { model.notify("Launch at login could not be changed: " + error.localizedDescription); enabled = SMAppService.mainApp.status == .enabled }
            }
    }
}

extension View {
    /// A raised sheet behind the view. The sheet casts the shadow, not each word and button on it.
    func raisedSheet<S: InsettableShape>(_ shape: S, shadow: Color, radius: CGFloat, y: CGFloat) -> some View {
        background(shape.fill(Palette.surfaceRaised).shadow(color: shadow, radius: radius, y: y))
            .overlay(shape.strokeBorder(Palette.borderSubtle))
    }
}
