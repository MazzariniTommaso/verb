import AppKit
import SwiftUI
import VerbCore
import VerbEngine

/// Renders every page, both appearances and both languages, to PNG files for design review:
///
///     release/Verb.app/Contents/MacOS/Verb --render-snapshots /path/to/folder
///
/// It uses a throwaway profile with sample content and never starts the microphone,
/// the keyboard tap, global shortcuts or a model engine, so real data is never touched.
@MainActor enum Snapshots {
    static func render(to directory: URL) {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("verb-snapshots-" + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let model = try AppModel(dataDirectory: root, services: false)
            try seed(model)
            // The microphones of a laptop with AirPods on and a USB headset: real devices are never listed.
            let microphones = [MicrophoneDevice(id: "usb", name: "Jabra Evolve2 30", deviceID: 1, kind: .wired),
                               MicrophoneDevice(id: "airpods", name: "AirPods Pro", deviceID: 2, kind: .headset),
                               MicrophoneDevice(id: "mac", name: "MacBook Pro Microphone", deviceID: 3, kind: .builtIn),
                               MicrophoneDevice(id: "iphone", name: "iPhone Microphone", deviceID: 4, kind: .phone)]
            model.microphones = microphones; model.automaticMicrophone = microphones[0]
            ShimmerText.still = true
            defer { ShimmerText.still = false }
            var count = 0
            // `--only welcome,tour` renders just the images whose names start that way.
            let arguments = CommandLine.arguments
            let only = arguments.firstIndex(of: "--only").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1].split(separator: ",").map(String.init) : nil }
            func wanted(_ name: String) -> Bool { only.map { $0.contains { name.hasPrefix($0) } } ?? true }
            for dark in [false, true] {
                for language in InterfaceLanguage.allCases {
                    model.settings.interfaceOptions.language = language
                    let t = Lang(language: language)
                    let suffix = "\(language.rawValue)-\(dark ? "dark" : "light")"
                    func save<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat? = nil) throws {
                        guard wanted(name) else { return }
                        try snap(view.environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale), width: width, height: height, dark: dark,
                                 to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                        count += 1
                    }
                    // Pure SwiftUI views go through ImageRenderer, which draws rounded shapes exactly as the screen does.
                    func draw<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat) throws {
                        guard wanted(name) else { return }
                        try render(view.environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale), width: width, height: height, dark: dark,
                                   to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                        count += 1
                    }
                    for page in Page.allCases {
                        model.page = page
                        try save("page-\(page.rawValue.lowercased())", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                        // And in the smallest window.
                        try save("page-\(page.rawValue.lowercased())-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                    }
                    // Every page as the window widens: small, medium, large with cards side by side,
                    // and at its largest. The sidebar stays whole; the icons alone are its own render.
                    for page in Page.allCases {
                        model.page = page
                        for (name, width, height) in [("compact", 820.0, 640.0), ("regular", 900, 680), ("wide", 1440, 900), ("max", Sizing.windowMaxWidth, Sizing.windowMaxHeight)] {
                            try save("window-\(page.rawValue.lowercased())-\(name)", MainView().modifier(WindowChrome()), width: width, height: height)
                        }
                    }
                    // The sidebar with its icons alone, as ⌃⌘S leaves it, in the smallest window and the usual one.
                    model.settings.sidebarCollapsed = true
                    for page in [Page.home, .settings] {
                        model.page = page
                        try save("window-\(page.rawValue.lowercased())-icons-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                        try save("window-\(page.rawValue.lowercased())-icons", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    }
                    model.settings.sidebarCollapsed = false
                    // Each page of Settings, whole and in the smallest window. Slack has words of its own.
                    model.settings.appStyles["web:gmail"] = .formal
                    model.settings.personalInstructions = t("I’m Tom, product lead at Verb. I sign emails “Tom”.", "Sono Tom, responsabile di prodotto in Verb. Firmo le email “Tom”.")
                    model.settings.customMeetingTemplates = [MeetingTemplate(id: "board", name: t("Board", "Consiglio"), instruction: t("Decisions, owners and dates only.", "Solo decisioni, responsabili e date."))]
                    model.settings.appStyles["com.tinyspeck.slackmacgap"] = .custom
                    model.settings.stylePrompts["com.tinyspeck.slackmacgap"] = t("Short and friendly, no full stop at the end", "Brevi e cordiali, senza punto finale")
                    model.page = .settings
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try save("settings-\(tab.rawValue)", MainView().modifier(WindowChrome()), width: 1080, height: 1100)
                        try save("settings-\(tab.rawValue)-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                    }
                    model.settingsTab = .general
                    // Tall enough for the whole page.
                    for (page, height) in [(Page.models, 2300.0), (.home, 2100)] {
                        model.page = page
                        try save("full-\(page.rawValue.lowercased())", MainView().modifier(WindowChrome()), width: 1080, height: height)
                    }
                    // Both stages on servers, remote processing still off: the speech server on this Mac answers, the hosted writing server is refused.
                    let local = model.settings
                    model.settings.speechProvider = .endpoint; model.settings.speechEndpoint = "http://localhost:8000/v1/audio/transcriptions"
                    model.settings.cleanupProvider = .endpoint; model.settings.hostedCleanupModel = "llama-3.3-70b-versatile"; model.page = .models
                    model.endpointTrials = ["speech": EndpointTrial(passed: true, text: "1.2 s · “See you tomorrow at three.”"), "writing": EndpointTrial(passed: false, text: "Remote processing is off. Turn on “Allow remote processing” in Settings → Privacy to use this server.")]
                    try save("full-models-servers", MainView().modifier(WindowChrome()), width: 1080, height: 2300)
                    model.settings = local; model.endpointTrials = [:]
                    // Each page with nothing in it yet.
                    let library = model.library, notes = model.notes, open = model.openNote
                    model.history = []; model.library.vocabulary = []; model.library.snippets = []; model.library.transforms = []; model.notes = []; model.openNote = nil
                    for page in [Page.history, .dictionary, .snippets, .transforms, .notes] {
                        model.page = page
                        try save("page-\(page.rawValue.lowercased())-empty", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    }
                    model.library = library; model.notes = notes; model.openNote = open; model.reloadHistory()
                    // The notepad over other apps: at its smallest, where it shows one note at a time, and
                    // its list asked for; just wide enough for the list beside the note; at its largest.
                    try save("panel-notepad", NotesPanelView(), width: Sizing.notepadMinWidth, height: Sizing.notepadMinHeight)
                    try save("panel-notepad-list", NotesPanelView(showingList: true), width: Sizing.notepadMinWidth, height: Sizing.notepadMinHeight)
                    try save("panel-notepad-regular", NotesPanelView(), width: Sizing.notepadListBelow, height: 420)
                    try save("panel-notepad-max", NotesPanelView(), width: Sizing.notepadMaxWidth, height: Sizing.notepadMaxHeight)
                    // A recording dragged over History, about to be dropped.
                    model.page = .history
                    try save("page-history-drop", MainView().modifier(WindowChrome()).environment(\.previewingDrop, true), width: 1080, height: 780)

                    // A first launch: nothing dictated, nothing set up.
                    let history = model.history, latest = model.latestText, stats = model.stats
                    model.history = []; model.latestText = ""; model.stats = DictationStats(); model.microphoneGranted = false; model.speechInstalled = false
                    model.page = .home
                    try save("page-home-empty", MainView().modifier(WindowChrome()), width: 1080, height: 900)
                    model.history = history; model.latestText = latest; model.stats = stats; model.microphoneGranted = true; model.speechInstalled = true

                    // Dictation in progress, then the moments after it.
                    // Six seconds of made-up speech, held at one moment so every image shows the same ink.
                    model.meter.preview((0..<600).map { index in let x = Double(index) / 10; return Float(max(0, sin(x * 0.32) * 0.55 + sin(x * 1.7) * 0.2 + 0.25)) })
                    model.phase = .recording; model.handsFree = true; model.elapsed = 12
                    try save("page-home-recording", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    // The overlay at the bottom in each style: speaking, under the pointer, open with
                    // the words, at work and done. The made-up speech is held at one moment.
                    let chosen = model.settings.overlayStyle
                    let said = t("Let’s meet on Wednesday at three.", "Ci vediamo mercoledì alle tre."), saying = t("I’ll bring the slides", "Porto io le slide")
                    for style in OverlayStyle.allCases where style != .notch {
                        model.settings.overlayStyle = style
                        model.phase = .recording; model.handsFree = true; model.elapsed = 12; model.outcome = .none
                        try save("overlay-\(style.rawValue)-recording", OverlayBackdrop(), width: 460, height: 120)
                        try save("overlay-\(style.rawValue)-pointer", OverlayBackdrop(pointer: true), width: 460, height: 120)
                        model.liveText = said; model.liveTentative = saying
                        try save("overlay-\(style.rawValue)-words", OverlayBackdrop(), width: 520, height: 180)
                        model.liveText = ""; model.liveTentative = ""
                        model.phase = .polishing
                        try save("overlay-\(style.rawValue)-working", OverlayBackdrop(), width: 460, height: 120)
                        model.phase = .idle; model.outcome = .delivered; model.status = "Paste sent to Mail"
                        try save("overlay-\(style.rawValue)-done", OverlayBackdrop(), width: 460, height: 120)
                    }
                    model.settings.overlayStyle = .pill
                    model.phase = .recording; model.outcome = .none
                    // Over real content: a dark editor and a white page.
                    try save("overlay-recording-over-editor", OverlayBackdrop(ground: .editor), width: 460, height: 120)
                    try save("overlay-recording-over-page", OverlayBackdrop(ground: .page), width: 460, height: 120)
                    // Every style side by side, to choose one.
                    if wanted("overlay-board") { try board(model, t, dark: dark, to: directory.appendingPathComponent("overlay-board-\(suffix).png")); count += 1 }

                    // What the overlay says once it opens, the same in every style: at the bottom with
                    // the Pill, and at the top on a MacBook's notch, on a display with neither notch
                    // nor menu bar, and on one with a menu bar.
                    let opened = Snapshots.openStates(model, t)
                    for state in opened where state.bottom {
                        state.apply()
                        try save("overlay-\(state.name)", OverlayBackdrop(), width: 560, height: state.height + 40)
                        Snapshots.calm(model)
                    }
                    model.settings.overlayStyle = .notch
                    for (screen, tag) in [(Snapshots.laptop, ""), (Snapshots.display, "-plain"), (Snapshots.displayWithBar, "-bar")] {
                        func island(_ name: String, height: CGFloat, pointer: Bool = false, near: Bool = false, room: CGFloat? = nil) throws {
                            try save("overlay-notch-\(name)\(tag)", NotchBackdrop(screen: screen, hover: Snapshots.island(screen, pointer: pointer, near: near, room: room)), width: 600, height: height)
                        }
                        // At rest: the notch alone; without one, the tab as the pointer comes near.
                        model.phase = .idle; model.outcome = .none; model.overlayResting = true
                        try island("rest", height: 80)
                        try island("rest-near", height: 80, near: true)
                        try island("rest-pointer", height: 80, pointer: true)
                        model.overlayResting = false
                        // Closed: symbols beside the notch.
                        model.phase = .recording; model.handsFree = true; model.elapsed = 12
                        try island("recording", height: 80)
                        // The menus of the app in front reach the notch: the dot goes to the right.
                        if tag.isEmpty { try island("recording-crowded", height: 80, room: 12) }
                        model.phase = .polishing
                        try island("working", height: 80)
                        try island("working-pointer", height: 120, pointer: true)
                        model.phase = .idle; model.outcome = .delivered; model.status = "Paste sent to Mail"
                        try island("done", height: 80)
                        model.outcome = .copied
                        try island("copied", height: 80)
                        model.outcome = .none; model.overlayResting = true
                        model.meeting = .recording(Date().addingTimeInterval(-754))
                        try island("meeting", height: 80)
                        try island("meeting-pointer", height: 120, pointer: true)
                        model.meeting = .writing("Writing the notes")
                        try island("writing", height: 80)
                        model.meeting = .idle; model.overlayResting = false
                        // Open: one rectangle from the top edge, the words below.
                        for state in opened where tag.isEmpty || state.everyScreen {
                            state.apply()
                            try island(state.name, height: state.height + 40)
                            Snapshots.calm(model)
                        }
                    }
                    model.settings.overlayStyle = chosen
                    model.phase = .idle; model.outcome = .delivered; model.status = "Ready when you are"; model.meter.reset()

                    // Sheets and the menu header.
                    if let record = model.history.first { try save("sheet-history", HistoryDetail(record: record), width: 680) }
                    if let failed = model.history.first(where: { $0.status == .failed }) { try save("sheet-history-failed", HistoryDetail(record: failed), width: 680) }
                    try save("sheet-word", WordEditor(entry: VocabularyEntry(word: "")), width: 460)
                    try save("sheet-snippet", SnippetEditor(entry: model.library.snippets[0]), width: 520)
                    try save("sheet-transform", TransformEditor(entry: model.library.transforms[0]), width: 500)
                    // The window that listens for new keys: waiting, with keys that work, and with keys that don't.
                    try save("sheet-keys", KeyCaptureSheet(target: .dictation), width: 520)
                    try save("sheet-keys-captured", KeyCaptureSheet(target: .dictation, captured: KeyBinding(modifiers: [.control, .option], keyCode: 2, label: "⌃ ⌥ D")), width: 520)
                    try save("sheet-keys-problem", KeyCaptureSheet(target: .dictation, captured: KeyBinding(modifiers: [.option], label: "⌥")), width: 520)
                    // Keys another command had: they will move, and it will have none.
                    try save("sheet-keys-taken", KeyCaptureSheet(target: .transform(model.library.transforms[0].id), captured: .controlCommandC), width: 520)
                    // Keys well-known apps use: they can be chosen, and the window names who loses them.
                    try save("sheet-keys-caution", KeyCaptureSheet(target: .copyLast, captured: .shiftCommandC), width: 520)
                    // The microphone test: one listening now, and what the others heard.
                    let tested = MicrophoneTester(results: ["usb": .init(verdict: .clear, voice: -30, room: -62, startup: 0.05),
                                                            "mac": .init(verdict: .tooNoisy, voice: -23, room: -31, startup: 0.04),
                                                            "iphone": .init(verdict: .noisy, voice: -26, room: -41, startup: 4.5)],
                                                  testing: "airpods", level: 0.62)
                    try save("sheet-microphones", MicrophoneTestSheet(tester: tested), width: 600)
                    try save("sheet-report", ReportSheet(), width: 560)
                    // A meeting being recorded, with its kind and the notes typed so far.
                    model.meeting = .recording(Date().addingTimeInterval(-754)); model.meetingKind = "client"
                    model.meetingNotes = t("Budget: ask Luca about Q3", "Budget: chiedere a Luca del Q3")
                    model.page = .notes
                    try save("page-notes-meeting", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    model.meeting = .idle; model.meetingNotes = ""
                    try save("menu-header", MenuHeader(title: t("Ready", "Pronto"), hint: model.shortcutHint(t)).background(Color(nsColor: .windowBackgroundColor)), width: 280, height: 52)
                    // Listening for "Ehi Verb": Home, the sidebar and the menu say so.
                    model.voiceListening = true; model.settings.voiceOptions.wakeWord = true; model.page = .home
                    try save("page-home-listening", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    try save("menu-header-listening", MenuHeader(title: t("Listening", "In ascolto"), hint: model.startHint(t), mark: .listening, markLabel: t("Listening", "In ascolto")).background(Color(nsColor: .windowBackgroundColor)), width: 280, height: 52)
                    model.voiceListening = false; model.settings.voiceOptions.wakeWord = false
                    // Keys that can't work: the menu says why instead of Ready.
                    try save("menu-header-problem", MenuHeader(title: t("Keys blocked", "Tasti bloccati"), hint: t("Terminal has secure input on", "Terminale ha l’input sicuro attivo"), mark: .problem, markLabel: t("Keys blocked", "Tasti bloccati")).background(Color(nsColor: .windowBackgroundColor)), width: 280, height: 52)

                    // Trying the phrase: the engine wrote it another way, which can be taught.
                    model.page = .settings; model.settingsTab = .voice
                    model.voiceTrial = .heard(.wake, text: "E verbe.", understood: false, lesson: VoiceCommands.Lesson(heard: "e verbe", command: nil))
                    try save("settings-trial", MainView().modifier(WindowChrome()), width: 1080, height: 1300)
                    model.voiceTrial = .heard(.finish, text: "Ever stop.", understood: false, lesson: VoiceCommands.Lesson(heard: "ever stop", command: "stop"))
                    try save("settings-trial-closing", MainView().modifier(WindowChrome()), width: 1080, height: 1300)
                    model.voiceTrial = .common(.wake, text: "Ever.", lesson: VoiceCommands.Lesson(heard: "ever", command: nil))
                    try save("settings-trial-common", MainView().modifier(WindowChrome()), width: 1080, height: 1300)
                    model.voiceTrial = .idle; model.settingsTab = .general

                    // More transforms than keys: the tenth and after are in the menu bar.
                    let transforms = model.library.transforms
                    model.library.transforms += (1...7).map { Transform(name: t("Prompt \($0)", "Prompt \($0)"), instruction: t("Rewrite the text as a short list of points.", "Riscrivi il testo come un breve elenco di punti.")) }
                    model.page = .transforms
                    try save("full-transforms-many", MainView().modifier(WindowChrome()), width: 1080, height: 1500)
                    model.library.transforms = transforms

                    // The welcome, page by page: the microphone allowed, Accessibility still to switch on,
                    // and the demo held while it speaks.
                    DemoVoice.frozen = 3.1
                    model.accessibilityGranted = false
                    for step in WelcomeStep.allCases {
                        model.welcome = step
                        try save("welcome-\(step.rawValue + 1)-\(step)", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                        // And in the narrowest window.
                        try save("welcome-\(step.rawValue + 1)-\(step)-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                    }
                    // The speech model on its way.
                    model.welcome = .models; model.speechInstalled = false; model.downloadingSpeech = true; model.downloadProgress = 0.42; model.downloadStatus = "Downloading Parakeet v3…"
                    try save("welcome-3-models-downloading", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    try save("welcome-3-models-downloading-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                    model.speechInstalled = true; model.downloadingSpeech = false; model.downloadProgress = 0; model.downloadStatus = ""
                    model.accessibilityGranted = true
                    // Two gestures tried, and Verb hearing the third.
                    model.welcome = .practice
                    let sheet = t("Let’s meet on Wednesday at three.\nThis week I finished the draft, and on Friday I’ll send it to Giulia.", "Ci vediamo mercoledì alle tre.\nQuesta settimana ho finito la bozza, e venerdì la mando a Giulia.")
                    model.phase = .recording; model.handsFree = false
                    try save("welcome-4-practice-tried", WelcomeView(step: .practice, sheet: sheet, tried: [.hold, .handsFree]).frame(width: 1080, height: 780).background(Palette.surfacePage), width: 1080, height: 780)
                    model.phase = .idle
                    model.welcome = nil
                    DemoVoice.frozen = nil

                    // The tour at a few of its stops.
                    for stop in [0, 2, 3, 6, 7] {
                        model.moveTour(to: stop)
                        try save("tour-\(stop + 1)", MainView().modifier(WindowChrome()), width: 1080, height: 780)
                    }
                    model.moveTour(to: 3)
                    try save("tour-4-narrow", MainView().modifier(WindowChrome()), width: Sizing.windowMinWidth, height: Sizing.windowMinHeight)
                    model.endTour()
                }
            }
            // The lockup for the brand book, on a transparent ground: ink for light pages, ivory for dark ones.
            for dark in [false, true] where wanted("lockup") {
                try render(Lockup(), width: 640, height: 280, dark: dark, to: directory.appendingPathComponent("lockup-\(dark ? "ivory" : "ink").png"))
                count += 1
            }
            print("Rendered \(count) images to \(directory.path)")
        } catch {
            FileHandle.standardError.write(Data("Snapshot rendering failed: \(error.localizedDescription)\n".utf8))
        }
    }

    static let quietHover = OverlayHover()
    static let pointerHover: OverlayHover = { let hover = OverlayHover(); hover.inside = true; return hover }()
    /// The island on a 14-inch MacBook Pro, its notch 185 points wide and 32 tall, and on a
    /// display without a notch or a menu bar; the pointer away or over it.
    static let laptop = IslandGeometry.screen(width: 1512, left: CGSize(width: 663.5, height: 32), right: CGSize(width: 663.5, height: 32), safeTop: 32, menuBar: 33)
    static let display = IslandGeometry.screen(width: 1920, left: nil, right: nil, safeTop: 0, menuBar: 0)
    static let displayWithBar = IslandGeometry.screen(width: 1920, left: nil, right: nil, safeTop: 0, menuBar: 25)
    static func island(_ geometry: IslandGeometry, pointer: Bool, near: Bool = false, room: CGFloat? = nil) -> OverlayHover {
        let hover = OverlayHover(); hover.island = geometry; hover.inside = pointer; hover.near = near; hover.leftRoom = room; return hover
    }

    /// One open state of the overlay: its name, how to set it up, how tall it stands, and
    /// whether it is drawn at the bottom and on every screen too.
    struct OpenState {
        let name: String
        let height: CGFloat
        var bottom = true
        var everyScreen = false
        let apply: () -> Void
    }
    /// Every way the overlay opens, with sample words.
    static func openStates(_ model: AppModel, _ t: Lang) -> [OpenState] {
        let said = t("Let’s meet on Wednesday at three.", "Ci vediamo mercoledì alle tre."), saying = t("I’ll bring the slides", "Porto io le slide")
        let speaking: () -> Void = { model.phase = .recording; model.handsFree = true; model.elapsed = 12; model.outcome = .none; model.liveText = said; model.liveTentative = saying }
        let question = t("How far is the Moon from the Earth?", "Quanto dista la Luna dalla Terra?")
        let answer = t("On average **384,400 km**. It varies from about 363,000 km at its closest (perigee) to 405,000 km at its farthest (apogee), because the orbit is an ellipse.",
                       "In media **384.400 km**. Non è sempre la stessa: va da circa 363.000 km quando è più vicina (perigeo) a 405.000 km quando è più lontana (apogeo), perché l’orbita è un’ellisse.")
        let dictation = t("Hi Marco, I can confirm Wednesday’s meeting at three. I’ll bring the slides with the quarter’s numbers and a proposal for November’s budget. If you can, send the agenda first so we can prepare.",
                          "Ciao Marco, ti confermo la riunione di mercoledì alle tre. Porto io le slide con i numeri del trimestre e una proposta per il budget di novembre. Se riesci, mandami prima l’ordine del giorno così ci prepariamo con calma.")
        return [
            OpenState(name: "words", height: 92, everyScreen: true, apply: speaking),
            OpenState(name: "silence", height: 112, apply: { speaking(); model.silenceLeft = 3 }),
            OpenState(name: "edit", height: 112, apply: { speaking(); model.previewMode = .command; model.liveText = t("make it more formal", "rendilo più formale"); model.liveTentative = t("and shorter", "e più breve") }),
            OpenState(name: "empty", height: 72, apply: { model.phase = .idle; model.outcome = .empty; model.status = "No speech detected" }),
            OpenState(name: "cancelled", height: 82, apply: { model.phase = .idle; model.outcome = .cancelled; model.restorable = CancelledDictation(record: DictationRecord(duration: 4), target: nil, settings: model.settings, library: model.library) }),
            OpenState(name: "failed", height: 90, apply: { model.phase = .idle; model.outcome = .failed; model.status = "Couldn't finish dictation"; model.keptRecording = true }),
            OpenState(name: "box", height: Sizing.overlayBoxHeight, everyScreen: true, apply: { model.phase = .idle; model.outcome = .copyOnly; model.status = TextInserter.keptNoField; model.pasteBox = dictation }),
            OpenState(name: "box-copied", height: Sizing.overlayBoxHeight, apply: { model.phase = .idle; model.outcome = .copyOnly; model.pasteBox = dictation; model.pasteCopied = true }),
            OpenState(name: "ask-listening", height: Sizing.overlayBoxHeight, apply: { speaking(); model.askingOnly = true; model.liveText = t("How far is the Moon", "Quanto dista la Luna"); model.liveTentative = t("from the Earth", "dalla Terra") }),
            OpenState(name: "ask-thinking", height: Sizing.overlayBoxHeight, apply: { model.phase = .polishing; model.askingOnly = true; model.answer = AnswerCard(request: question, streaming: true) }),
            OpenState(name: "ask-answer", height: Sizing.overlayBoxHeight, everyScreen: true, apply: { model.phase = .idle; model.outcome = .delivered; model.askingOnly = true; model.answer = AnswerCard(request: question, text: answer, canInsert: true); model.answerArmed = true }),
            OpenState(name: "ask-follow-up", height: Sizing.overlayBoxHeight, apply: {
                model.phase = .idle; model.outcome = .delivered; model.askingOnly = true
                let next = t("And the Sun?", "E il Sole?"), sun = t("On average about **149.6 million km**: the astronomical unit. It is a little closer in January, a little farther in July.",
                                                                       "In media circa **149,6 milioni di km**: è l’unità astronomica. A gennaio è un po’ più vicino, a luglio un po’ più lontano.")
                model.conversation = [Assistant.Turn(question: question, answer: answer), Assistant.Turn(question: next, answer: sun)]
                model.answer = AnswerCard(request: next, text: sun)
            }),
            OpenState(name: "files", height: Sizing.overlayBoxHeight, apply: {
                model.phase = .idle; model.outcome = .delivered
                model.answer = AnswerCard(request: t("Find the file budget 2026", "Cerca il file budget 2026"),
                                          files: ["~/Documents/Budget 2026.xlsx", "~/Documents/Clients/Budget 2026 - draft.docx", "~/Desktop/budget-2026-notes.md"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            }),
            OpenState(name: "meeting-offer", height: 90, apply: { model.phase = .idle; model.outcome = .none; model.meetingOffer = "Zoom" }),
            OpenState(name: "meeting-ended", height: 90, apply: { model.phase = .idle; model.outcome = .none; model.meetingEnded = "Microsoft Teams" }),
            OpenState(name: "coach-click", height: 82, apply: { model.phase = .idle; model.outcome = .none; model.coach = .click(app: t("Messages", "Messaggi"), bundleID: "com.apple.MobileSMS") }),
            OpenState(name: "suggestion", height: 90, apply: { model.phase = .idle; model.outcome = .none; model.pendingSuggestion = VocabularySuggestion(word: "Tommaso", heardAs: "Tomaso") }),
        ]
    }
    /// Back to nothing showing, after an open state.
    static func calm(_ model: AppModel) {
        model.phase = .idle; model.outcome = .none; model.status = "Ready when you are"
        model.liveText = ""; model.liveTentative = ""; model.silenceLeft = nil; model.previewMode = nil
        model.restorable = nil; model.keptRecording = false; model.pasteBox = nil; model.pasteCopied = false
        model.askingOnly = false; model.answer = nil; model.answerArmed = false; model.conversation = []
        model.meetingOffer = nil; model.meetingEnded = nil; model.coach = nil; model.pendingSuggestion = nil
    }

    /// The styles at the bottom in the states that matter, side by side.
    private static func board(_ model: AppModel, _ t: Lang, dark: Bool, to url: URL) throws {
        let saved = model.settings.overlayStyle
        defer { model.settings.overlayStyle = saved; calm(model) }
        let recording: () -> Void = { calm(model); model.phase = .recording; model.handsFree = true; model.startedByVoice = false; model.elapsed = 12 }
        let states: [(title: String, pointer: Bool, apply: () -> Void)] = [
            (t("Recording", "In registrazione"), false, recording),
            (t("Pointer over it", "Con il puntatore"), true, recording),
            (t("Working", "In elaborazione"), false, { calm(model); model.phase = .transcribing }),
            (t("Voice edit", "Modifica a voce"), false, { calm(model); model.phase = .polishing; model.rewrite = .voiceEdit }),
            (t("Done", "Fatto"), false, { calm(model); model.rewrite = nil; model.outcome = .delivered }),
            (t("Copied", "Copiata"), false, { calm(model); model.outcome = .copied }),
            (t("No speech", "Nessuna voce"), false, { calm(model); model.outcome = .empty; model.status = "No speech detected" }),
        ]
        func cell(_ pointer: Bool) throws -> NSImage {
            try image(OverlayView(meter: model.meter).environmentObject(model).environmentObject(pointer ? pointerHover : quietHover)
                        .environment(\.lang, t).environment(\.locale, t.locale), dark: dark)
        }
        var rows: [BoardRow] = []
        for style in OverlayStyle.allCases where style != .notch {
            model.settings.overlayStyle = style
            var cells: [NSImage] = []
            for state in states { state.apply(); cells.append(try cell(state.pointer)) }
            rows.append(BoardRow(title: style.title(t), detail: style.detail(t), cells: cells))
        }
        model.rewrite = nil
        try renderFitted(OverlayBoard(columns: states.map(\.title), rows: rows, t: t), dark: dark, to: url)
    }

    private static func image<V: View>(_ view: V, dark: Bool) throws -> NSImage {
        var result: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            result = renderer.nsImage
        }
        guard let result else { throw VerbError("Could not render an overlay.") }
        return result
    }

    private static func renderFitted<V: View>(_ view: V, dark: Bool, to url: URL) throws {
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw VerbError("Could not render \(url.lastPathComponent).") }
        try data.write(to: url)
    }

    private static func seed(_ model: AppModel) throws {
        let now = Date()
        let samples: [(hours: Double, app: String, bundle: String, text: String, mode: CaptureMode, status: SessionStatus, error: String?)] = [
            (-0.4, "Mail", "com.apple.mail", "Ci vediamo mercoledì alle tre in ufficio. Porto io i documenti firmati e la bozza del contratto, così li rivediamo insieme.", .dictation, .completed, nil),
            (-2.2, "Slack", "com.tinyspeck.slackmacgap", "Thanks for the notes. I'll send the revised draft tomorrow morning, before the call.", .dictation, .completed, nil),
            (-5.1, "Notes", "com.apple.Notes", "Idee per la presentazione: aprire con il caso di Torino, poi i numeri del trimestre, chiudere con le domande.", .dictation, .completed, nil),
            (-26, "Safari", "com.apple.Safari", "", .dictation, .failed, "No words were recognized."),
            (-27, "Pages", "com.apple.iWork.Pages", "Il progetto parte a ottobre, con una prima consegna entro fine mese.", .command, .completed, nil),
            (-74, "Messages", "com.apple.MobileSMS", "Arrivo tra dieci minuti, tienimi un posto.", .dictation, .completed, nil),
        ]
        for sample in samples {
            // A failed dictation keeps its audio, as it would with the default settings, so it can be recovered.
            var audioName: String?
            if sample.status == .failed {
                audioName = UUID().uuidString + ".wav"
                try Data(count: 64).write(to: model.paths.audio.appendingPathComponent(audioName!))
            }
            let record = DictationRecord(createdAt: now.addingTimeInterval(sample.hours * 3600), duration: Double(sample.text.count) / 14 + 2, rawText: sample.text, text: sample.text,
                                         appName: sample.app, bundleID: sample.bundle, language: sample.text.hasPrefix("Thanks") ? "en" : "it", engine: "parakeet-v3", mode: sample.mode, status: sample.status,
                                         audioName: audioName, error: sample.error, processingSeconds: 1.4, delivery: sample.status == .completed ? "Paste sent to \(sample.app)" : "")
            try model.store.save(record)
        }
        model.reloadHistory()
        model.latestText = samples[0].text
        // The app's own status stays at its idle text: Home must show each dictation's outcome, not this.
        model.status = "Ready when you are"
        model.outcome = .delivered
        var library = model.library
        library.vocabulary = [VocabularyEntry(word: "Verb"), VocabularyEntry(word: "MLX", heardAs: "emme elle ics"), VocabularyEntry(word: "Parakeet", heardAs: "para kit")]
        library.snippets = [Snippet(trigger: "la mia firma", expansion: "Un caro saluto,\nT."), Snippet(trigger: "my address", expansion: "Via Roma 1, 20121 Milano")]
        model.library = library
        // Totals of a few weeks of use, so the numbers on Home read as they will.
        var stats = DictationStats(words: 12_480, seconds: 4_920, dictations: 214)
        stats.voicedWords = 9_870; stats.voicedSeconds = 3_410; stats.fixes = 1_236
        // Fifteen weeks of made-up days, most weekdays dictated, a run up to today.
        let calendar = Calendar.current
        for offset in 0..<105 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let weekend = calendar.isDateInWeekend(day)
            let words = offset < 6 ? 60 + offset * 23 : (offset * 37 % 11 < (weekend ? 2 : 7) ? (offset * 53) % 180 + 20 : 0)
            if words > 0 { stats.days[DictationStats.day(day)] = words }
        }
        stats.apps = ["Claude": 5_210, "Mail": 3_140, "Slack": 2_460, "Notes": 1_670]
        model.stats = stats
        // A few notes, one of them a meeting's.
        let folder = model.notesFolder
        _ = try NotesStore.create(in: folder, text: "# Lancio di ottobre\n\nAprire con il caso di Torino, poi i numeri del trimestre.\n\n- chiedere a Giulia le slide\n- provare la demo venerdì", now: Date().addingTimeInterval(-3_600))
        let lines = [Utterance(speaker: .you, start: 2, end: 9, text: "Partiamo dal budget del lancio: siamo a 40.000 euro."),
                     Utterance(speaker: .others, start: 11, end: 19, text: "Va bene, ma la campagna video va spostata a novembre."),
                     Utterance(speaker: .you, start: 21, end: 26, text: "D’accordo. Preparo io la nuova tabella entro giovedì.")]
        let transcript = MeetingNotes.transcript(lines, you: "Tu", others: "Altri")
        let summary = "**In breve**\n- Budget del lancio a 40.000 euro.\n- Campagna video spostata a novembre.\n\n**Prossimi passi**\n- Tu: nuova tabella del budget entro giovedì."
        _ = try NotesStore.create(in: folder, text: MeetingNotes.document(title: "Riunione del 25 settembre, 10:30", date: Date().addingTimeInterval(-86_400), minutes: 34, summary: summary, transcript: transcript, headings: ("Note", "Trascrizione")),
                                  suffix: "Riunione", now: Date().addingTimeInterval(-86_400))
        _ = try NotesStore.create(in: folder, text: "Idee sparse per Verb: provare il blocco note sopra Xcode, dettare le note delle riunioni.", now: Date().addingTimeInterval(-172_800))
        model.reloadNotes()
        model.speechInstalled = true
        model.writerModels = [model.settings.cleanupModel]
        model.microphoneGranted = true
        model.accessibilityGranted = true
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, to url: URL) throws {
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height))
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw VerbError("Could not render \(url.lastPathComponent).") }
        try data.write(to: url)
    }

    private static func snap<V: View>(_ view: V, width: CGFloat, height: CGFloat?, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let size = CGSize(width: width, height: height ?? max(120, host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        if height == nil { host.frame.size.height = max(120, host.fittingSize.height); window.setContentSize(host.frame.size) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw VerbError("Could not allocate a bitmap for \(url.lastPathComponent).") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // Let the view go: a window kept around would lay itself out again at every later change of the model.
        window.orderOut(nil); window.contentView = nil
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VerbError("Could not encode \(url.lastPathComponent).") }
        try data.write(to: url)
    }
}

/// The window's close, minimise and zoom buttons where macOS draws them. A capture of the view
/// alone leaves them out; drawn here, a render shows what they line up with.
private struct WindowChrome: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        let frame = model.windowButtons.frame
        content.overlay(alignment: .topLeading) {
            HStack(spacing: (frame.width - 42) / 2) {
                ForEach([NSColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
                    Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12).frame(width: 14, height: frame.height)
                }
            }
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The sidebar's lockup at six times its size: the mark 1.35 times the height of the word, its
/// point dropping below the baseline like a descender.
private struct Lockup: View {
    var body: some View {
        HStack(spacing: 60) {
            VerbMark().fill(Palette.accent).frame(width: 162, height: 120)
            Text("Verb").font(Typeface.display(120, .medium)).tracking(-1.8).foregroundStyle(Palette.textPrimary)
        }
    }
}

private struct BoardRow {
    let title: String
    let detail: String
    let cells: [NSImage]
}

/// The comparison sheet for the overlay styles.
private struct OverlayBoard: View {
    let columns: [String]
    let rows: [BoardRow]
    let t: Lang
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(t("The overlay at the bottom, in five styles", "La capsula in basso, in cinque stili")).font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary)
                Text(t("Only symbols, numbers and keys on the row; words when it opens. In every style Space finishes and Escape cancels.", "Sulla riga solo simboli, numeri e tasti; le parole quando si apre. In ogni stile Spazio termina ed Esc annulla."))
                    .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Space.xxl, verticalSpacing: Space.xxl) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, title in
                        Text(title.uppercased()).font(Typeface.text(TypeSize.caption, .semibold)).tracking(Tracking.rubric).foregroundStyle(Palette.accent)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(Typeface.display(TypeSize.reading)).foregroundStyle(Palette.textPrimary)
                            Text(row.detail).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 180, alignment: .leading)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Image(nsImage: cell).shadow(color: Palette.shadow, radius: 10, y: 3)
                        }
                    }
                }
            }
        }
        .padding(Space.huge)
        .background(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom))
    }
}

/// The top of a screen, where the notch style hangs: its menu bar, with menus that reach the
/// notch when the room left of it is small, and the notch.
private struct NotchBackdrop: View {
    @EnvironmentObject var model: AppModel
    var screen = Snapshots.laptop
    var hover: OverlayHover
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom)
            if screen.menuBar > 0 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    // Menus up to the notch, as a busy app's are.
                    if let room = hover.leftRoom, let notch = screen.notch {
                        HStack(spacing: 18) {
                            ForEach(["Cronologia", "Segnalibri", "Finestra", "Aiuto"], id: \.self) { Text($0).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(nsColor: .labelColor)) }
                        }
                        .fixedSize()
                        .frame(width: 300 - notch.width / 2 - room - 8, alignment: .trailing)
                    }
                }
                .frame(height: screen.menuBar)
            }
            if let notch = screen.notch {
                UnevenRoundedRectangle(bottomLeadingRadius: NotchOverlay.notchRadius, bottomTrailingRadius: NotchOverlay.notchRadius, style: .continuous).fill(Palette.surfaceNotch).frame(width: notch.width, height: notch.height)
            }
            OverlayView(meter: model.meter).environmentObject(hover)
        }
    }
}

/// The overlay as it floats over another app, with a stand-in for the window shadow macOS draws.
private struct OverlayBackdrop: View {
    @EnvironmentObject var model: AppModel
    /// What the overlay sits on: the window's own colours, or real content such as a dark
    /// editor or a white page.
    enum Ground { case window, editor, page }
    var ground: Ground = .window
    var pointer = false
    var body: some View {
        ZStack {
            switch ground {
            case .window: LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom)
            case .editor:
                // Code in a dark theme, as in an editor or a terminal.
                ZStack(alignment: .topLeading) {
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<9, id: \.self) { line in
                            Text(["func finish() {", "    guard phase == .recording else { return }", "    recorder.stop()", "}", "", "// The keys came up.", "let words = text.split(separator: \" \")", "print(words.count)", "return words"][line])
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(line == 5 ? Color.gray : Color(red: 0.75, green: 0.8, blue: 0.85))
                        }
                    }
                    .padding(14)
                }
            case .page: Color.white
            }
            OverlayView(meter: model.meter).environmentObject(pointer ? Snapshots.pointerHover : Snapshots.quietHover)
        }
    }
}
