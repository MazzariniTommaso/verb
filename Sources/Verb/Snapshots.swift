import AppKit
import SwiftUI
import VerbCore

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
                        try save("page-\(page.rawValue.lowercased())", MainView(), width: 1080, height: 780)
                        // And in the smallest window.
                        try save("page-\(page.rawValue.lowercased())-narrow", MainView(), width: 900, height: 680)
                    }
                    // Tall enough for the whole page.
                    for (page, height) in [(Page.settings, 4000.0), (.models, 2300), (.home, 2100)] {
                        model.page = page
                        try save("full-\(page.rawValue.lowercased())", MainView(), width: 1080, height: height)
                    }
                    // Each page with nothing in it yet.
                    let library = model.library, notes = model.notes, open = model.openNote
                    model.history = []; model.library.vocabulary = []; model.library.snippets = []; model.library.transforms = []; model.notes = []; model.openNote = nil
                    for page in [Page.history, .dictionary, .snippets, .transforms, .notes] {
                        model.page = page
                        try save("page-\(page.rawValue.lowercased())-empty", MainView(), width: 1080, height: 780)
                    }
                    model.library = library; model.notes = notes; model.openNote = open; model.reloadHistory()
                    // The notepad over other apps, at its smallest.
                    try save("panel-notepad", NotesPanelView(), width: 560, height: 380)
                    // A recording dragged over History, about to be dropped.
                    model.page = .history
                    try save("page-history-drop", MainView().environment(\.previewingDrop, true), width: 1080, height: 780)

                    // A first launch: nothing dictated, nothing set up.
                    let history = model.history, latest = model.latestText, stats = model.stats
                    model.history = []; model.latestText = ""; model.stats = DictationStats(); model.microphoneGranted = false; model.speechInstalled = false
                    model.page = .home
                    try save("page-home-empty", MainView(), width: 1080, height: 900)
                    model.history = history; model.latestText = latest; model.stats = stats; model.microphoneGranted = true; model.speechInstalled = true

                    // Dictation in progress, then the moments after it.
                    // Six seconds of made-up speech, held at one moment so every image shows the same ink.
                    model.meter.preview((0..<600).map { index in let x = Double(index) / 10; return Float(max(0, sin(x * 0.32) * 0.55 + sin(x * 1.7) * 0.2 + 0.25)) })
                    model.phase = .recording; model.handsFree = true; model.elapsed = 12
                    try save("page-home-recording", MainView(), width: 1080, height: 780)
                    try draw("overlay-recording", OverlayBackdrop(), width: 460, height: 130)
                    // The classic capsule's captions. The longest: holding the key, past ten minutes.
                    let style = model.settings.overlayStyle
                    model.settings.overlayStyle = .classic
                    model.handsFree = false; model.elapsed = 754
                    try draw("overlay-recording-hold", OverlayBackdrop(), width: 460, height: 130)
                    model.handsFree = true; model.elapsed = 12
                    // Started with "Ehi Verb": the way to finish is spoken too.
                    model.startedByVoice = true
                    try draw("overlay-recording-voice", OverlayBackdrop(), width: 460, height: 130)
                    model.startedByVoice = false
                    model.settings.overlayStyle = style
                    // The words as they form: settled in ink, the part still being heard lighter.
                    model.liveText = t("Let’s meet on Wednesday at three at the office.", "Ci vediamo mercoledì alle tre in ufficio.")
                    model.liveTentative = t("I’ll bring the signed documents and", "Porto io i documenti firmati e")
                    try draw("overlay-preview", PreviewBackdrop(), width: 460, height: 230)
                    // A long dictation keeps its newest words in view.
                    model.liveText = t("Thanks for the notes on the draft. I went through all of them this morning and most are already in. The two about the budget need a call, because the numbers changed last week and I would rather explain than write.",
                                       "Grazie per le note sulla bozza. Le ho riviste tutte stamattina e quasi tutte sono già dentro. Le due sul budget richiedono una telefonata, perché i numeri sono cambiati la settimana scorsa e preferisco spiegarlo a voce.")
                    model.liveTentative = t("Are you free tomorrow", "Sei libero domani")
                    try draw("overlay-preview-long", PreviewBackdrop(), width: 460, height: 230)
                    model.liveText = ""; model.liveTentative = ""
                    model.phase = .polishing
                    // The spinner is an AppKit view, which ImageRenderer cannot draw. This capture adds hairlines at the capsule's ends that the screen never shows.
                    try save("overlay-working", OverlayBackdrop(), width: 460, height: 130)
                    // A voice edit on its way through the writing model: the pen writes by itself.
                    model.rewrite = .voiceEdit
                    try draw("overlay-editing", OverlayBackdrop(), width: 460, height: 130)
                    model.rewrite = nil
                    model.phase = .idle; model.outcome = .delivered; model.status = "Paste sent to Mail"
                    try draw("overlay-done", OverlayBackdrop(), width: 460, height: 130)
                    model.outcome = .failed; model.status = "Couldn't finish dictation"; model.keptRecording = true
                    try draw("overlay-failed", OverlayBackdrop(), width: 460, height: 130)
                    model.outcome = .cancelled; model.status = "Cancelled · recording saved"
                    try draw("overlay-cancelled", OverlayBackdrop(), width: 460, height: 130)
                    // Cancelled a moment ago: Restore writes it down after all.
                    model.restorable = CancelledDictation(record: DictationRecord(duration: 4), target: nil, settings: model.settings, library: model.library)
                    try draw("overlay-cancelled-restore", OverlayBackdrop(), width: 460, height: 130)
                    model.restorable = nil
                    // A word retyped after a dictation, offered to the dictionary.
                    model.pendingSuggestion = VocabularySuggestion(word: "Tommaso", heardAs: "Tomaso")
                    try draw("overlay-suggestion", OverlayBackdrop(), width: 460, height: 130)
                    model.pendingSuggestion = nil
                    // Nothing to type into, such as the desktop: the text waits as the last dictation, the clipboard untouched.
                    model.outcome = .copyOnly; model.status = TextInserter.keptNoField
                    try draw("overlay-kept", OverlayBackdrop(), width: 460, height: 130)
                    // The copy key put the last dictation on the clipboard.
                    model.outcome = .copied; model.status = "Copied to clipboard"
                    try draw("overlay-copied", OverlayBackdrop(), width: 460, height: 130)
                    model.keptRecording = false
                    // Every style side by side, to choose one.
                    if wanted("overlay-board") { try board(model, t, dark: dark, to: directory.appendingPathComponent("overlay-board-\(suffix).png")); count += 1 }
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
                    try save("sheet-keys-taken", KeyCaptureSheet(target: .transform(model.library.transforms[0].id), captured: .shiftCommandC), width: 520)
                    try save("menu-header", MenuHeader(title: t("Ready", "Pronto"), hint: model.shortcutHint(t), live: false).background(Color(nsColor: .windowBackgroundColor)), width: 280, height: 52)
                    // Listening for "Ehi Verb": Home, the sidebar and the menu say so.
                    model.voiceListening = true; model.settings.voiceOptions.wakeWord = true; model.page = .home
                    try save("page-home-listening", MainView(), width: 1080, height: 780)
                    try save("menu-header-listening", MenuHeader(title: t("Listening", "In ascolto"), hint: model.startHint(t), live: false).background(Color(nsColor: .windowBackgroundColor)), width: 280, height: 52)
                    model.voiceListening = false; model.settings.voiceOptions.wakeWord = false

                    // Trying the phrase: the engine wrote it another way, which can be taught.
                    model.page = .settings
                    model.voiceTrial = .heard(.wake, text: "E verbe.", understood: false, lesson: VoiceCommands.Lesson(heard: "e verbe", command: nil))
                    try save("full-settings-trial", MainView(), width: 1080, height: 2600)
                    model.voiceTrial = .heard(.finish, text: "Ever stop.", understood: false, lesson: VoiceCommands.Lesson(heard: "ever stop", command: "stop"))
                    try save("full-settings-trial-closing", MainView(), width: 1080, height: 2600)
                    model.voiceTrial = .common(.wake, text: "Ever.", lesson: VoiceCommands.Lesson(heard: "ever", command: nil))
                    try save("full-settings-trial-common", MainView(), width: 1080, height: 2600)
                    model.voiceTrial = .idle

                    // More transforms than keys: the tenth and after are in the menu bar.
                    let transforms = model.library.transforms
                    model.library.transforms += (1...7).map { Transform(name: t("Prompt \($0)", "Prompt \($0)"), instruction: t("Rewrite the text as a short list of points.", "Riscrivi il testo come un breve elenco di punti.")) }
                    model.page = .transforms
                    try save("full-transforms-many", MainView(), width: 1080, height: 1500)
                    model.library.transforms = transforms

                    // The welcome, page by page: the microphone allowed, Accessibility still to switch on,
                    // and the demo held while it speaks.
                    DemoVoice.frozen = 3.1
                    model.accessibilityGranted = false
                    for step in WelcomeStep.allCases {
                        model.welcome = step
                        try save("welcome-\(step.rawValue + 1)-\(step)", MainView(), width: 1080, height: 780)
                        // And in the narrowest window.
                        try save("welcome-\(step.rawValue + 1)-\(step)-narrow", MainView(), width: 900, height: 680)
                    }
                    // The speech model on its way.
                    model.welcome = .models; model.speechInstalled = false; model.downloadingSpeech = true; model.downloadProgress = 0.42; model.downloadStatus = "Downloading Parakeet v3 · MLX…"
                    try save("welcome-3-models-downloading", MainView(), width: 1080, height: 780)
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
                        try save("tour-\(stop + 1)", MainView(), width: 1080, height: 780)
                    }
                    model.moveTour(to: 3)
                    try save("tour-4-narrow", MainView(), width: 900, height: 680)
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

    /// The compact styles in the states that matter, side by side, with the classic capsule below.
    private static func board(_ model: AppModel, _ t: Lang, dark: Bool, to url: URL) throws {
        let saved = model.settings.overlayStyle
        defer { model.settings.overlayStyle = saved }
        let recording: () -> Void = { model.phase = .recording; model.handsFree = true; model.startedByVoice = false; model.elapsed = 12 }
        let states: [(title: String, pointer: Bool, apply: () -> Void)] = [
            (t("Recording", "In registrazione"), false, recording),
            (t("Pointer over it", "Con il puntatore"), true, recording),
            (t("Working", "In elaborazione"), false, { model.phase = .transcribing }),
            (t("Voice edit", "Modifica a voce"), false, { model.phase = .polishing; model.rewrite = .voiceEdit }),
            (t("Pointer over it", "Con il puntatore"), true, { model.phase = .polishing; model.rewrite = .voiceEdit }),
            (t("No text field", "Nessun campo"), false, { model.phase = .idle; model.rewrite = nil; model.outcome = .copyOnly; model.status = TextInserter.keptNoField }),
            (t("Done", "Fatto"), false, { model.phase = .idle; model.outcome = .delivered }),
            (t("Cancelled", "Annullata"), false, { model.phase = .idle; model.outcome = .cancelled; model.restorable = CancelledDictation(record: DictationRecord(duration: 4), target: nil, settings: model.settings, library: model.library) }),
        ]
        func cell(_ pointer: Bool) throws -> NSImage {
            try image(OverlayView(meter: model.meter).environmentObject(model).environmentObject(pointer ? pointerHover : quietHover)
                        .environment(\.lang, t).environment(\.locale, t.locale), dark: dark)
        }
        var rows: [BoardRow] = []
        for style in OverlayStyle.allCases where style != .classic {
            model.settings.overlayStyle = style
            var cells: [NSImage] = []
            for state in states { state.apply(); cells.append(try cell(state.pointer)) }
            rows.append(BoardRow(title: style.title(t), detail: style.detail(t), cells: cells))
        }
        model.settings.overlayStyle = .classic
        model.restorable = nil
        recording()
        let classic = try cell(false)
        try renderFitted(OverlayBoard(columns: states.map(\.title), rows: rows, classic: classic, t: t), dark: dark, to: url)
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
            (-26, "Safari", "com.apple.Safari", "", .dictation, .failed, "No words were recognized. You can listen to the recording and retry."),
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
        window.orderOut(nil)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VerbError("Could not encode \(url.lastPathComponent).") }
        try data.write(to: url)
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
    let classic: NSImage
    let t: Lang
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(t("The overlay in four compact styles", "La capsula in quattro stili compatti")).font(Typeface.display(TypeSize.title2)).foregroundStyle(Palette.textPrimary)
                Text(t("The small buttons show only under the pointer. In every style Space finishes and Escape cancels.", "I tasti piccoli compaiono solo sotto il puntatore. In ogni stile Spazio termina ed Esc annulla."))
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
            HStack(alignment: .center, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("Classic", "Classica")).font(Typeface.display(TypeSize.reading)).foregroundStyle(Palette.textPrimary)
                    Text(OverlayStyle.classic.detail(t)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                }
                .frame(width: 180, alignment: .leading)
                Image(nsImage: classic).shadow(color: Palette.shadow, radius: 10, y: 3)
            }
        }
        .padding(Space.huge)
        .background(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom))
    }
}

/// The preview card above the overlay, as the two panels stand on screen.
private struct PreviewBackdrop: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: -LivePreviewView.overlap) {
                LivePreviewView()
                OverlayView(meter: model.meter).environmentObject(Snapshots.quietHover)
            }
        }
    }
}

/// The overlay as it floats over another app, with a stand-in for the window shadow macOS draws.
private struct OverlayBackdrop: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)], startPoint: .top, endPoint: .bottom)
            OverlayView(meter: model.meter).environmentObject(Snapshots.quietHover)
        }
    }
}
