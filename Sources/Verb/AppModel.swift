import AppKit
import AVFoundation
import SwiftUI
import NaturalLanguage
import UniformTypeIdentifiers
import VerbCore
import VerbEngine

typealias Settings = VerbCore.Settings

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", notes = "Notes", dictionary = "Dictionary", snippets = "Snippets", transforms = "Transforms", models = "Models", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .home: return "house"; case .history: return "clock.arrow.circlepath"; case .notes: return "note.text"; case .dictionary: return "character.book.closed"; case .snippets: return "text.quote"; case .transforms: return "wand.and.stars"; case .models: return "square.stack.3d.up"; case .settings: return "gearshape" } }
}
enum Phase: String { case idle, authorizing, recording, transcribing, polishing, inserting, cancelling }
/// What the writing model rewrites, for the overlay: a voice edit, from the moment its keys are
/// let go, or a transform, by name.
enum Rewrite: Equatable { case voiceEdit, transform(String), ask }
/// A dictation cancelled a moment ago, with what it needs to be written down after all.
struct CancelledDictation {
    let record: DictationRecord
    let target: TextTarget?
    let settings: Settings
    let library: Library
    /// The names read from its field and the project it was dictated into.
    var terms: [String] = []
    var code: (root: String?, paths: Bool)? = nil
    /// How long Restore is offered, in seconds.
    static let window: Double = 8
    /// A recording at least this long, in seconds, stays in History as cancelled once Restore
    /// is gone, for Retry until it expires: too much to lose to a stray Escape.
    static let kept: Double = 15
}
/// Says something to VoiceOver at once, whatever has the focus: how a dictation ended, a
/// problem, a copy. The overlay never takes the focus, so this is how its news is heard.
@MainActor enum Announcer {
    static func say(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Waits for the writing model's answer, or for the moment to stop waiting: the deadline,
/// Escape or a cancel. The model's own work may go on a moment longer, unseen.
@MainActor final class PolishWait {
    private var continuation: CheckedContinuation<Result<String, Error>?, Never>?
    private var timer: Task<Void, Never>?
    func wait(for work: Task<String, Error>, seconds: Double) async -> Result<String, Error>? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self?.end() }
            }
            Task { [weak self] in let result = await work.result; self?.end(result) }
        }
    }
    /// Stops waiting, with the answer if there is one; nil means the words go in as said.
    func end(_ answer: Result<String, Error>? = nil) {
        timer?.cancel(); timer = nil
        continuation?.resume(returning: answer); continuation = nil
    }
}

/// A server endpoint tried from Models: under way, or how it went and what came back.
struct EndpointTrial: Equatable {
    var running = false
    var passed = false
    var text = ""
}

/// A shorter history, or audio no longer kept: what it would delete at once.
struct PendingPrune: Identifiable {
    let id = UUID()
    let retention: Retention
    let keepAudio: Bool
    let entries: Int
    let recordings: Int
}

/// A meeting whose notes couldn't be written, and the folder that keeps its recordings.
struct FailedMeeting: Identifiable, Equatable {
    let folder: URL
    let started: Date
    var id: URL { folder }
}

/// How the last dictation ended, so the overlay can show a tick, a warning or nothing.
/// `copied` means the copy key put the last dictation on the clipboard; `copyOnly` means the
/// text was not pasted and waits as the last dictation, for the paste-last and copy keys.
enum Outcome { case none, delivered, copied, copyOnly, failed, cancelled, empty
    /// A word went into the dictionary. `status` says which.
    case learned
    /// Something couldn't start, such as a voice edit with nothing selected. `status` says what.
    case hint
    static func of(delivery: String) -> Outcome { delivery.hasPrefix("Paste sent") || ["Written in your note", "Written on the practice sheet", "Written in Verb"].contains(delivery) ? .delivered : .copyOnly }
}

/// The microphone level, a hundred values a second, each with the moment it was heard. Views
/// read it as they draw, on every frame of the display, so recording never redraws the window.
@MainActor final class LevelMeter: ObservableObject {
    /// One level for every 10 ms of audio.
    static let step = 0.01
    /// macOS hands over microphone audio every 100 ms. Drawing this far behind the newest level
    /// moves evenly between two deliveries; the overlay's voice draws the newest instead (`live`).
    static let delay = 0.14
    private static let kept = 8.0
    private(set) var times: [Double] = []
    private(set) var levels: [Float] = []
    private var smoothed: Float = 0
    /// A fixed moment to draw instead of the clock, for the snapshot renderer.
    var frozen: Double?

    func push(_ values: [Float], at time: Double) {
        guard !values.isEmpty else { return }
        var moment = max((times.last ?? -.infinity) + Self.step, time - Double(values.count - 1) * Self.step)
        for value in values {
            // Quick to spread, slower to fade, like ink on paper.
            smoothed += (value - smoothed) * (value > smoothed ? 0.55 : 0.2)
            times.append(moment); levels.append(smoothed); moment += Self.step
        }
        if let cut = times.firstIndex(where: { $0 >= time - Self.kept }), cut > 0 { times.removeFirst(cut); levels.removeFirst(cut) }
    }
    func reset() { times = []; levels = []; smoothed = 0; frozen = nil }
    /// Fills the meter with made-up levels ending now, and holds that moment. For snapshots.
    func preview(_ values: [Float]) {
        reset()
        let end = Date().timeIntervalSinceReferenceDate
        push(values, at: end)
        frozen = (times.last ?? end) + Self.delay
    }
    /// The moment the views draw: a little behind the clock, or the held one.
    func now(_ date: Date) -> Double { (frozen ?? date.timeIntervalSinceReferenceDate) - Self.delay }
    /// The level at a moment, between the two nearest values. After the newest it fades out.
    func level(at time: Double) -> Float {
        guard let first = times.first, let last = times.last, time > first else { return 0 }
        if time >= last { return levels[levels.count - 1] * Float(max(0, 1 - (time - last) / 0.3)) }
        var low = 0, high = times.count - 1
        while high - low > 1 { let middle = (low + high) / 2; if times[middle] <= time { low = middle } else { high = middle } }
        let fraction = Float((time - times[low]) / max(times[high] - times[low], 0.000_1))
        return levels[low] + (levels[high] - levels[low]) * fraction
    }
}

/// A one-off check, started from Settings, of how Verb hears the wake or the closing phrase.
enum VoiceTrial: Equatable {
    enum Kind: Equatable { case wake, finish }
    case idle
    case listening(Kind)
    /// What the engine wrote, whether Verb understood it, and what it could learn from it.
    case heard(Kind, text: String, understood: Bool, lesson: VoiceCommands.Lesson?)
    /// The engine wrote ordinary words for the wake phrase ("ever"). Taught, they would start
    /// Verb whenever a sentence opens with them, so this asks before it teaches.
    case common(Kind, text: String, lesson: VoiceCommands.Lesson)
    case silent(Kind)
    /// A misheard spelling added to the dictionary as the phrase.
    case taught(Kind, heard: String, meaning: String)
}

/// A dictation or a voice edit written straight into one of Verb's own sheets, with how it was
/// made: the welcome's practice follows these.
struct SheetWriting: Equatable {
    let id = UUID()
    let mode: CaptureMode
    let handsFree: Bool
    let text: String
}

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page = .home
    /// The page of Settings in view.
    @Published var settingsTab: SettingsTab = .general
    /// An entry to open as History appears, as from Home's “Open in History”.
    @Published var historyFocus: UUID?
    /// The welcome, at the step it shows, in place of the pages; nil once it is done.
    @Published var welcome: WelcomeStep? {
        didSet { if initialized, let welcome, settings.welcomeStep != welcome.rawValue { settings.welcomeStep = welcome.rawValue } }
    }
    /// The tour of the window, at the stop it shows; nil when no tour runs.
    @Published var tourStop: Int?
    /// The stops of the tour that runs, or ran last.
    var tourStops: [TourStop] = TourStop.all
    /// The last dictation or voice edit written into a note or the practice sheet.
    @Published var sheetWriting: SheetWriting?
    @Published var settings: Settings { didSet { if initialized { persistSettings(old: oldValue) } } }
    @Published var library: Library { didSet { if initialized { do { try JSONStore.save(library, to: paths.library); if oldValue.transforms.map(\.keys) != library.transforms.map(\.keys) { configureKeys() } } catch { notify(error.localizedDescription) } } } }
    /// Totals over every dictation, which History's clean-ups leave alone.
    @Published var stats = DictationStats()
    @Published var history: [DictationRecord] = []
    @Published var phase: Phase = .idle
    /// Set while a voice edit or a transform runs; nil while the model only tidies up a dictation.
    @Published var rewrite: Rewrite?
    /// A dictation cancelled a moment ago, still on disk: Restore writes it down after all.
    @Published var restorable: CancelledDictation?
    private var restoreExpiry: Task<Void, Never>?
    /// Turns the Mac's sound down while you dictate.
    let ducker = AudioDucker()
    /// Frees the models' memory after a while without dictating.
    private var idleUnload: Task<Void, Never>?
    /// How long a dictation can run: four hours on this Mac; twenty minutes with a hosted
    /// server, which takes one upload of limited size.
    var longestDictation: Double { (sessionSettings ?? settings).speechProvider == .endpoint ? 1200 : SpeechPCM.longest }
    private var lastCheckpoint = Date()
    /// Once a minute, a long dictation keeps its words so far in History, in case Verb stops before it ends.
    func checkpoint() {
        guard phase == .recording, var record = activeRecord, Date().timeIntervalSince(lastCheckpoint) >= 60, (sessionSettings ?? settings).retention != .none else { return }
        lastCheckpoint = Date()
        let words = livePreview.settled
        guard !words.isEmpty, words != record.rawText else { return }
        record.rawText = words; activeRecord = record
        try? store.save(record)
    }
    /// Memory and processor use, for the Models page.
    let resources = ResourceMonitor()
    /// A word you retyped after a dictation, offered in the overlay.
    @Published var pendingSuggestion: VocabularySuggestion?
    /// Words noticed in your corrections, not yet added or turned down. In memory only.
    @Published var suggestions: [VocabularySuggestion] = []
    /// Watches the field after a paste for the words you retype.
    var learner: Task<Void, Never>?
    /// The answer to a request made with the command keys, or what an action found, in a card over the overlay.
    @Published var answer: AnswerCard?
    /// A dictation that found no field, waiting in the overlay's box until it is copied or closed.
    @Published var pasteBox: String?
    /// The box's text went on the clipboard: it says so, then closes.
    @Published var pasteCopied = false
    /// The last text went in with the paste key, for the overlay's symbol.
    @Published var pastedLast = false
    /// The session began with the ask keys: what is said is a question, answered in the box.
    @Published var askingOnly = false
    /// The questions and answers while the box stays open, so the next question follows on.
    var conversation: [Assistant.Turn] = []
    /// An app for calls started using the microphone: the overlay offers to record it.
    @Published var meetingOffer: String?
    /// The call being recorded seems over: the overlay asks whether to stop.
    @Published var meetingEnded: String?
    /// Notices calls, and calls that end.
    var meetingWatch = MeetingWatch()
    var meetingWatchTimer: Timer?
    /// The first dictation in an app, guided step by step.
    @Published var coach: CoachStep?
    var coachTask: Task<Void, Never>?
    /// Seconds left before a hands-free dictation finishes on silence, in its last few.
    @Published var silenceLeft: Int?
    /// The overlay has shown how the last dictation ended: the notch style shrinks to its drop.
    @Published var overlayResting = false
    /// Where the window's close, minimise and zoom buttons are, as the window measures them; the
    /// sidebar with its icons alone stands on their middle.
    @Published var windowButtons = WindowButtons(frame: CGRect(x: Sizing.windowButtonsLeft, y: Sizing.windowButtonsTop, width: Sizing.windowButtonsWidth, height: Sizing.windowButtonsHeight))
    /// The kind of notes the meeting being recorded gets, and what you type while it runs.
    @Published var meetingKind = MeetingTemplate.general
    @Published var meetingNotes = ""
    /// The problem report is open.
    @Published var reporting = false
    /// Lone modifier presses a moment ago, for the hint about the dictation keys.
    var lonePresses: [Date] = []
    /// How long each microphone took to open, its last three times.
    var microphoneOpenings: [String: [Double]] = [:]
    /// Parts of the recording already written down while it runs, so the end waits only for the rest.
    var ahead: TranscriptAhead?
    /// The site in the browser the dictation is for, when the browser shows one Verb knows.
    var sessionSite: Site?
    /// Where the answer can go, and whether Return and Escape act on the card: until another key or a click.
    var answerTarget: TextTarget?
    var answerArmed = false
    var answerTask: Task<Void, Never>?
    /// Names and terms read from the field when the dictation began.
    private var sessionTerms: [String] = []
    /// The notes, newest first, and the one open.
    @Published var notes: [Note] = []
    @Published var openNote: URL?
    /// A meeting being recorded, or written down after it.
    @Published var meeting: MeetingState = .idle
    /// The note editor, while it exists; what Verb writes goes there when it has the cursor.
    weak var noteEditor: NoteEditing?
    let meetingRecorder = MeetingRecorder()
    /// Dictations made during a meeting, in seconds from its start: they stay out of its transcript.
    var meetingDictations: [ClosedRange<Double>] = []
    private var dictationInMeeting: Double?
    /// Tells the menu bar that a meeting started or ended.
    var menuChanged: (() -> Void)?
    /// Opens or closes the notepad panel.
    var toggleNotepad: (() -> Void)?
    /// The words you have dictated, with how often, for putting back English words the engine wrote the Italian way.
    private var englishLexicon: [String: Int] = [:]
    /// Projects read for code names, by folder.
    private var codeProjects: [String: CodeProject] = [:]
    /// The project of the editor or terminal being dictated into, and whether mentions take paths (terminals do).
    private var sessionCode: (root: String?, paths: Bool)?
    @Published var outcome: Outcome = .none
    /// Whether the dictation that just failed or was cancelled left a recording History can retry.
    @Published var keptRecording = false
    /// The dictation keys went down while the last dictation was still being written: nothing
    /// records, and the overlay says so for a moment.
    @Published var pressedWhileBusy = false
    private var pressedWhileBusyEnd: Task<Void, Never>?
    let meter = LevelMeter()
    @Published var elapsed: Double = 0
    @Published var status = "Ready when you are"
    @Published var notice: String?
    /// A history or audio setting that would delete something now, waiting for a yes.
    @Published var pendingPrune: PendingPrune?
    /// Meetings that couldn't be written down, with their recordings, until retried or deleted.
    @Published var failedMeetings: [FailedMeeting] = []
    /// Problems said while the window was out of sight, newest first, until shown or dismissed:
    /// the menu lists them and marks its icon.
    @Published var unread: [String] = []
    /// Whether the main window is in front, where a notice is seen as it comes.
    var windowInView: () -> Bool = { false }
    /// The last dictation went in as said because the writing model failed or took too long.
    @Published var asSaid = false
    /// A long recording asked for a second Escape before it is cancelled.
    @Published var cancelArmed = false
    /// How far long work has come, from 0 to 1: a long recording being written down, or a long
    /// text refined part by part. Nil for work too short to need it.
    @Published var workProgress: Double?
    /// How far a meeting being written down has come, from 0 to 1.
    @Published var meetingProgress: Double?
    private var disarm: Task<Void, Never>?
    /// Waiting for the writing model on the dictation under way, which Escape or the deadline ends.
    private var polishWait: PolishWait?
    private var polishSkipped = false
    /// A writing model that just failed rests for three minutes, so the dictations meanwhile
    /// don't each wait for it to fail again. Choosing another one ends the rest.
    private var writerRest: (until: Date, writer: String)?
    @Published var latestText = ""
    @Published var latestOriginal = ""
    @Published var selectedRecord: UUID?
    @Published var speechInstalled = false
    @Published var writerModels: [String] = []
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var downloadingSpeech = false
    @Published var downloadingWriter = false
    /// A download you stopped: it carries on from where it was at the next try.
    @Published var downloadStopped = false
    /// Where the download under way began, for the time it still needs.
    private(set) var downloadBaseline: (date: Date, progress: Double)?
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    /// An app holding secure input, which keeps Verb's keys from Verb; empty when it can't be named.
    @Published var keysBlockedBy: String?
    /// Verb turned the Mac's sound down for this dictation: the overlay shows it.
    @Published var soundLowered = false
    /// The microphones someone speaks into, and the chosen one whatever it is.
    @Published var microphones: [MicrophoneDevice] = []
    /// The one the automatic choice would use now.
    @Published var automaticMicrophone: MicrophoneDevice?
    @Published var handsFree = false
    /// The microphone is open between dictations, waiting for "Ehi Verb".
    @Published var voiceListening = false {
        // Listening needed the speech model; once it stops, the model leaves memory in its own time.
        didSet { if oldValue, !voiceListening { scheduleIdleUnload() } }
    }
    /// The current or last dictation began with "Ehi Verb".
    @Published var startedByVoice = false
    @Published var harnessCatalogs: [String: HarnessCatalog] = [:]
    @Published var harnessLoading = false
    @Published var harnessError: String?
    @Published var harnessTestResult: String?
    /// Whether the last CLI test worked, for its tone.
    @Published var harnessTestPassed = false
    /// The last try of a server endpoint from Models, by stage: "speech" or "writing".
    @Published var endpointTrials: [String: EndpointTrial] = [:]
    @Published var harnessTesting = false
    var harnessTask: Task<Void, Never>?
    var harnessTestTask: Task<Void, Never>?
    var harnessRequest = UUID()
    let paths: DataPaths
    let store: HistoryStore
    let speech: LocalSpeech
    let client = ModelClient()
    let recorder = Recorder()
    let inserter = TextInserter()
    let writer: LocalWriterProcess
    let hotkeys = Hotkeys()
    private var initialized = false
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var permissionTicks = 0
    private var nextRetentionCheck = Date().addingTimeInterval(3600)
    var activeTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var operation: UUID?
    private var activeRecord: DictationRecord?
    private var activeTarget: TextTarget?
    private var sessionSettings: Settings?
    private var sessionLibrary: Library?
    private var recordingStarted: Date?
    private var stopWhenReady = false
    private var listeningReady = false
    private var listenProblem: String?
    private var voiceCheck: Task<Void, Never>?
    private var voiceReader = VoiceCommands.Reader()
    private var queuedMoment: SpeechMoment?
    private var speaking = false
    private var heardSpeech = false
    private var lastSpeech = Date()
    /// Locked or asleep: nobody is at the Mac, so Verb stops listening for its name.
    private var screenLocked = false, screensAsleep = false
    /// Where the microphone's stream stood when the dictation keys went down.
    private var preparedPosition: Int?
    /// Why the dictation being processed is kept in History instead of pasted, if it is.
    private var holdPaste: String?
    /// What went wrong with the recording itself, said with the result.
    private var recordingProblem: String?
    /// Set when the microphone delivered nothing at all: what to say instead of “no speech”.
    private var silentMicrophone: String?
    /// Set while the last moment of speech is still arriving after the keys came up.
    private var finishing = false
    private var observers: [NSObjectProtocol] = []
    /// The live preview: words already settled, and the part still being spoken.
    @Published var liveText = ""
    @Published var liveTentative = ""
    private var liveOffset = 0
    private var pendingLiveCommit: Int?
    private var liveTask: Task<Void, Never>?
    private var liveTimer: Timer?
    @Published var voiceTrial: VoiceTrial = .idle {
        // A try of the phrase loads the speech model: it leaves memory as after a dictation.
        didSet { if case .listening = oldValue { scheduleIdleUnload() } }
    }
    private var trialTimeout: Task<Void, Never>?
    private var lastWarmUp = Date.distantPast
    var showWindow: (() -> Void)?
    var phaseChanged: (() -> Void)?
    /// Shows the overlay's last outcome for a moment although nothing is running, as after ⌃⌘C.
    var flashOutcome: (() -> Void)?
    var interfaceChanged: (() -> Void)?
    private let services: Bool

    var busy: Bool { phase != .idle }
    /// False while the interface is drawn alone, for snapshots and checks: no engine may start.
    var runsServices: Bool { services }
    var writerReady: Bool {
        switch settings.cleanupProvider {
        case .off: return true
        case .local: return writerModels.contains(settings.cleanupModel)
        case .endpoint: return !settings.hostedCleanupModel.isEmpty && (try? EndpointPolicy.validate(settings.cleanupEndpoint, allowRemote: settings.allowRemoteProcessing)) != nil
        case .harness: return settings.allowRemoteProcessing && harnessExecutable != nil && harnessCatalog?.models.contains(where: { $0.id == settings.harnessOptions.model }) == true
        }
    }
    var activeMode: CaptureMode? { previewMode ?? activeRecord?.mode }
    /// A mode to draw the overlay in without a session, for the snapshot renderer.
    var previewMode: CaptureMode?
    /// Speech can be recognised: the model is on this Mac, or a server is set up and allowed.
    var speechReady: Bool {
        guard settings.speechProvider == .endpoint else { return speechInstalled }
        return !settings.speechModel.isEmpty && (try? EndpointPolicy.validate(settings.speechEndpoint, allowRemote: settings.allowRemoteProcessing)) != nil
    }
    /// The writing model is at work, or a voice edit is on its way to it: the overlay draws the
    /// pen writing by itself instead of the spinner.
    var modelAtWork: Bool { phase == .polishing || (rewrite != nil && (phase == .transcribing || phase == .inserting)) }
    /// Whether dictation can work with no window: at login Verb stays in the menu bar only then.
    var readyForBackground: Bool { microphoneGranted && accessibilityGranted && speechReady }

    /// `services: false` loads data without touching the microphone, hotkeys or model engines,
    /// for rendering the interface in isolation.
    init(dataDirectory: URL? = nil, services: Bool = true) throws {
        self.services = services
        paths = try DataPaths(root: dataDirectory)
        let loaded = try JSONStore.load(Settings.self, from: paths.settings, fallback: Settings())
        settings = loaded
        // Verb's own transforms follow the interface's language; edited ones stay as they are.
        let italian = loaded.interfaceOptions.language == .italian
        var words = try JSONStore.load(Library.self, from: paths.library, fallback: Library(italian: italian))
        words.localizeStandardTransforms(italian: italian)
        library = words
        store = try HistoryStore(paths: paths)
        speech = LocalSpeech(root: paths.models, bundledRoot: Bundle.main.resourceURL?.appendingPathComponent("MLXModels"))
        writer = LocalWriterProcess(paths: paths)
        let interrupted = try store.recoverInterrupted(); try store.prune(retention: settings.retention, keepAudio: settings.keepAudio)
        try store.removeOrphanedAudio()
        history = try store.all(); latestText = history.first(where: { !$0.text.isEmpty })?.text ?? ""; latestOriginal = history.first(where: { !$0.rawText.isEmpty })?.rawText ?? ""
        // The first time, the totals start from what History still holds.
        if FileManager.default.fileExists(atPath: paths.stats.path) { stats = (try? JSONStore.load(DictationStats.self, from: paths.stats, fallback: DictationStats())) ?? DictationStats(history: history) }
        else { stats = DictationStats(history: history); try? JSONStore.save(stats, to: paths.stats) }
        speechInstalled = speech.installed(settings.localModel)
        harnessCatalogs = (try? JSONStore.load([String: HarnessCatalog].self, from: paths.root.appendingPathComponent("harness-catalogs.json"), fallback: [:])) ?? [:]
        initialized = true
        pruneMeetings()
        resources.writerProcess = { [weak self] in self?.writer.pid }
        reloadNotes()
        recorder.preferBuiltIn = settings.preferBuiltInMic
        for record in history where record.mode == .dictation { learnWords(of: record.rawText) }
        noticeRecurringNames()
        // Totals without days or apps take them from what History holds.
        if stats.days.isEmpty, !history.isEmpty {
            let seed = DictationStats(history: history)
            stats.days = seed.days; stats.apps = seed.apps
            try? JSONStore.save(stats, to: paths.stats)
        }
        refreshPermissions()
        guard services else { return }
        // Said once, at the launch that found them: the menu keeps it until it is seen.
        if interrupted > 0 { notify(interrupted == 1 ? "A dictation was cut short when Verb last closed. Retry it from History." : "\(interrupted) dictations were cut short when Verb last closed. Retry them from History.") }
        // An app that hangs answers Accessibility late or never: Verb asks for half a second, not
        // the six it would otherwise wait at every dictation.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        alignAppLanguage()
        ducker.restoreLeftover()
        recorder.onLevel = { [weak self] values in self?.meter.push(values, at: Date().timeIntervalSinceReferenceDate) }
        recorder.onInterruption = { [weak self] in self?.finish(); self?.notify("The microphone went away. Processing the audio captured so far.") }
        recorder.onSpeech = { [weak self] moment in self?.heard(moment) }
        // The disk stopped taking the recording: end now, with what was saved.
        recorder.onFailure = { [weak self] in if self?.phase == .recording { self?.finish(tail: false) } }
        recorder.onFallback = { [weak self] name in guard let self else { return }; self.notify("Using \(name.isEmpty ? self.lang("Microphone", "Microfono") : name): the chosen microphone isn’t available.") }
        // Open but silent, as a device another app holds or a driver that hangs: end now and say which.
        recorder.onNoSound = { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.silentMicrophone = (self.recorder.inputName.isEmpty ? "The microphone" : self.recorder.inputName) + " sent no sound. Choose another microphone in Settings."
            self.finish(tail: false)
        }
        // The microphone opens as the dictation keys go down, so the first word is heard.
        // Any other app is asked as the keys go down, while the dictation is still to start.
        hotkeys.onPending = { [weak self] _ in self?.prepareMicrophone(); if let front = NSWorkspace.shared.frontmostApplication { FieldReach.wake(front) } }
        hotkeys.onAbandon = { [weak self] in self?.recorder.release(); self?.preparedPosition = nil }
        hotkeys.onOtherKey = { [weak self] in self?.abandonUnspoken() }
        hotkeys.onDown = { [weak self] mode in self?.shortcutDown(mode) }
        hotkeys.onUp = { [weak self] in self?.shortcutUp() }
        hotkeys.onHandsFree = { [weak self] in self?.holdToHandsFree() }
        hotkeys.onCopy = { [weak self] in self?.copyLast() }
        hotkeys.onNotepad = { [weak self] in self?.abandonUnspokenVoiceEdit(); self?.toggleNotepad?() }
        hotkeys.onToggle = { [weak self] in self?.toggle() }
        hotkeys.isHandsFreeActive = { [weak self] in guard let self else { return false }; return self.handsFree && (self.phase == .recording || self.phase == .authorizing) }
        hotkeys.onStopHandsFree = { [weak self] in guard let self else { return }; if self.phase == .authorizing { self.stopWhenReady = true } else { self.finish() } }
        hotkeys.onCancel = { [weak self] in self?.escape() }
        hotkeys.onPaste = { [weak self] in self?.pasteLast() }
        hotkeys.onTransform = { [weak self] index in self?.applyTransform(index) }
        // Escape is Verb's only while you speak and while the writing model works on a dictation:
        // otherwise it stays with the app, as in Vim or a dialog.
        hotkeys.isRecording = { [weak self] in guard let self else { return false }; return self.phase == .recording || self.phase == .authorizing || self.phase == .polishing }
        hotkeys.onClash = { [weak self] message in self?.notify(message) }
        hotkeys.onLoneModifiers = { [weak self] modifiers, held in self?.lonePress(modifiers, held: held) }
        hotkeys.onTypedLong = { [weak self] count in self?.typedLong(count) }
        hotkeys.isAnswerArmed = { [weak self] in self?.answerArmed == true && (self?.answer != nil || self?.pasteBox != nil) }
        hotkeys.onAnswerKey = { [weak self] key in
            guard let self else { return }
            if self.pasteBox != nil { if key == 53 { self.closePasteBox() } else { self.copyPasteBox() }; return }
            if key == 53 { self.closeAnswer() } else { self.useAnswer() }
        }
        hotkeys.onAnyOtherKey = { [weak self] in self?.answerArmed = false }
        recorder.onOpened = { [weak self] id, name, seconds in self?.microphoneOpened(id: id, name: name, seconds: seconds) }
        // Someone who has dictated for a while is past the first days: no hints for beginners.
        if settings.coaching?.firstRun == nil { settings.coachingState.firstRun = stats.dictations > 20 ? .distantPast : Date() }
        watchMeetings()
        configureKeys()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        watchDevices()
        // Listening for the wake phrase pauses while the screen is locked or asleep.
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screenLocked = true; self?.endForAbsence(); self?.refreshListening() } },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screenLocked = false; self?.refreshListening() } },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screensAsleep = true; self?.endForAbsence(); self?.refreshListening() } },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screensAsleep = false; self?.refreshListening() } },
            // Chromium and Electron apps you dictate into show their text to Verb once asked, before a dictation needs it.
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in if self?.dictatedInto(app) == true { FieldReach.wake(app) } }
            },
        ]
        Task { [weak self] in
            guard let self else { return }
            if self.speechInstalled { try? await self.speech.prepare(self.settings.localModel) }
            await self.recoverMeetings()
            self.scheduleIdleUnload()
            if self.settings.cleanupProvider == .local, self.writer.available {
                do { try await self.writer.start(); self.writerModels = try await self.client.localModels(); self.warmWriter() } catch { /* Shown when the user enables or downloads the writing model. */ }
            }
        }
        listeningReady = true
        refreshListening()
        if let front = NSWorkspace.shared.frontmostApplication, dictatedInto(front) { FieldReach.wake(front) }
    }
    /// Every few seconds while something is still to allow or the window is in front; every
    /// quarter of a minute otherwise, as nothing there changes by itself.
    func refreshPermissions() {
        permissionTicks += 1
        let thorough = !initialized || !microphoneGranted || !accessibilityGranted || windowInView() || permissionTicks % 5 == 0
        guard thorough else { return }
        // Assigned only when they change, so the window doesn't redraw every few seconds.
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, trusted = AXIsProcessTrusted()
        if microphoneGranted != microphone { microphoneGranted = microphone; menuChanged?() }
        if accessibilityGranted != trusted {
            // Lost while Verb runs, as after an update: the keys stop, and the fix is said at once.
            if services, initialized, accessibilityGranted { notify(AppModel.accessibilityLost) }
            accessibilityGranted = trusted; menuChanged?()
        }
        if services {
            if trusted { hotkeys.installTap() } else { hotkeys.removeTap() }
            let blocked = Hotkeys.secureInputApp()
            if keysBlockedBy != blocked { keysBlockedBy = blocked; menuChanged?() }
        }
        // The list of microphones follows Core Audio's own notice of a change (see watchDevices).
        if microphones.isEmpty { refreshMicrophones() }
        if !busy && Date() >= nextRetentionCheck {
            nextRetentionCheck = Date().addingTimeInterval(3600)
            do { try store.prune(retention: settings.retention, keepAudio: settings.keepAudio); pruneMeetings(); reloadHistory() } catch { notify(error.localizedDescription) }
        }
        refreshListening()
    }
    /// Whether you have dictated into this app, as History and the totals remember.
    func dictatedInto(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName ?? "", id = app.bundleIdentifier ?? ""
        return stats.apps[name] != nil || history.contains { $0.bundleID == id }
    }
    /// What macOS adds to Verb, such as its panels, and the language VoiceOver reads it in follow
    /// the interface's language from the next launch, not the Mac's.
    private func alignAppLanguage() {
        guard services else { return }
        let code = settings.interfaceOptions.language == .italian ? "it" : "en"
        if UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first != code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }
    func refreshMicrophones() {
        // Devices that pass audio between apps, as Pro Tools' or a call's, are left out.
        let inputs = Microphones.list().filter { $0.kind != nil || $0.id == settings.microphoneID }
        if microphones != inputs { microphones = inputs }
        let automatic = Microphones.pick("", preferBuiltIn: settings.preferBuiltInMic)?.device
        if automaticMicrophone != automatic { automaticMicrophone = automatic }
    }
    /// A microphone plugged in or taken out, or macOS's own changed: Core Audio says so, and the list follows.
    private func watchDevices() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
        }
    }
    func requestMicrophone() { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() } }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func notify(_ message: String) {
        notice = message
        Announcer.say(lang.message(message))
        guard !windowInView() else { return }
        unread.removeAll { $0 == message }
        unread.insert(message, at: 0)
        if unread.count > 5 { unread.removeLast(unread.count - 5) }
        menuChanged?()
    }
    /// Shows a problem in the window, the newest when none is named, and counts it as read.
    func showProblem(_ message: String? = nil) {
        if let message = message ?? unread.first ?? notice {
            notice = message
            unread.removeAll { $0 == message }
            menuChanged?()
        }
        showWindow?()
    }
    func dismissNotice() {
        if let notice { unread.removeAll { $0 == notice } }
        notice = nil; menuChanged?()
    }
    func clearUnread() { unread = []; menuChanged?() }
    func setPhase(_ value: Phase) {
        let old = phase
        phase = value
        if value == .recording, old != .recording { lowerSound() } else if old == .recording, value != .recording { ducker.restore(); soundLowered = false }
        // Once it is all over, with the microphone closed: VoiceOver hears how it ended, and a
        // failure has a sound of its own.
        if value == .idle, old != .idle, services {
            if outcome == .failed, (sessionSettings ?? settings).soundFeedback { NSSound(named: "Basso")?.play() }
            let said = announcement(lang)
            Task { try? await Task.sleep(nanoseconds: 200_000_000); Announcer.say(said) }
        }
        phaseChanged?()
    }
    /// A moment into the dictation the start sound plays, then music and videos go quiet. Keys
    /// pressed for another shortcut in that moment end it with neither (see abandonUnspoken).
    private func lowerSound() {
        guard services else { return }
        let id = operation, snapshot = sessionSettings ?? settings
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.phase == .recording, self.operation == id else { return }
            if snapshot.soundFeedback { NSSound(named: "Tink")?.play() }
            guard snapshot.duckAudio else { return }
            // Once the start sound has played.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.phase == .recording, self.operation == id else { return }
            self.ducker.duck()
            self.soundLowered = self.ducker.isLowered
        }
    }
    private func persistSettings(old: Settings) {
        do {
            try JSONStore.save(settings, to: paths.settings)
            if old.localModel != settings.localModel {
                speechInstalled = speech.installed(settings.localModel)
                let variant = settings.localModel
                Task { [weak self] in
                    guard let self, self.settings.localModel == variant else { return }
                    await self.speech.unload()
                    guard self.settings.localModel == variant, self.speech.installed(variant) else { return }
                    try? await self.speech.prepare(variant)
                }
            }
            if old.keyOptions != settings.keyOptions { configureKeys() }
            if old.preferBuiltInMic != settings.preferBuiltInMic { recorder.preferBuiltIn = settings.preferBuiltInMic; refreshMicrophones(); if !busy { refreshListening() } }
            if old.microphoneID != settings.microphoneID { refreshMicrophones() }
            if old.interfaceOptions != settings.interfaceOptions {
                if old.interfaceOptions.language != settings.interfaceOptions.language {
                    var updated = library; updated.localizeStandardTransforms(italian: settings.interfaceOptions.language == .italian)
                    if updated != library { library = updated }
                    alignAppLanguage()
                }
                interfaceChanged?()
            }
            if old.voiceOptions != settings.voiceOptions || old.microphoneID != settings.microphoneID || old.localModel != settings.localModel { refreshListening() }
            if old.cleanupProvider != settings.cleanupProvider || old.cleanupModel != settings.cleanupModel || old.cleanupPolicy != settings.cleanupPolicy { lastWarmUp = .distantPast; warmWriter() }
            if old.meetingDetection != settings.meetingDetection { watchMeetings() }
            if old.allowRemoteProcessing && !settings.allowRemoteProcessing {
                if busy { cancel() }; harnessTestTask?.cancel(); harnessTask?.cancel(); harnessLoading = false
            }
            // Allowed now: the CLI's models can be read.
            if !old.allowRemoteProcessing && settings.allowRemoteProcessing && settings.cleanupProvider == .harness { refreshHarness() }
            // Only a change to what is kept can remove anything; the rest never reads History.
            if !busy, old.retention != settings.retention || old.keepAudio != settings.keepAudio {
                try store.prune(retention: settings.retention, keepAudio: settings.keepAudio); pruneMeetings(); reloadHistory()
            }
        } catch { notify(error.localizedDescription) }
    }
    func reloadHistory() { do { history = try store.all() } catch { notify(error.localizedDescription) } }
    /// Changes what History keeps. A change that would delete entries or recordings now waits
    /// for a yes, with how many; nothing deleted can come back.
    func proposeKeeping(retention: Retention? = nil, keepAudio: Bool? = nil) {
        let retention = retention ?? settings.retention, keepAudio = keepAudio ?? settings.keepAudio
        let count = (try? store.pruneCount(retention: retention, keepAudio: keepAudio)) ?? (entries: 0, recordings: 0)
        let meetings = meetingsToPrune(retention: retention, keepAudio: keepAudio).count
        if count.entries + count.recordings + meetings == 0 { settings.retention = retention; settings.keepAudio = keepAudio; return }
        pendingPrune = PendingPrune(retention: retention, keepAudio: keepAudio, entries: count.entries, recordings: count.recordings + meetings)
    }
    func confirmPrune() {
        guard let pending = pendingPrune else { return }
        pendingPrune = nil
        settings.retention = pending.retention; settings.keepAudio = pending.keepAudio
    }
    /// The dictation or voice-edit keys went down: record while they are held.
    func shortcutDown(_ mode: CaptureMode) {
        guard !busy else { saidWhileBusy(); return }
        handsFree = false; begin(mode)
        // Turned down with a hint, as a voice edit with nothing selected: the microphone opened
        // as the keys went down closes again.
        if phase == .idle { recorder.release(); preparedPosition = nil }
    }
    /// Speaking now would be lost, so the overlay asks to wait instead of staying silent.
    private func saidWhileBusy() {
        guard phase != .recording, phase != .authorizing else { return }
        pressedWhileBusy = true
        pressedWhileBusyEnd?.cancel()
        pressedWhileBusyEnd = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.pressedWhileBusy = false
        }
    }
    /// The keys came up: the dictation ends, unless Space made it hands-free.
    func shortcutUp() {
        guard (phase == .recording || phase == .authorizing), !handsFree else { return }
        if phase == .authorizing { stopWhenReady = true } else { finish() }
    }
    /// Space with the dictation keys held: from here on the dictation goes on without them, and
    /// plain Space finishes it.
    func holdToHandsFree() {
        if phase == .recording || phase == .authorizing { if activeMode != .command { handsFree = true }; return }
        guard !busy else { return }
        handsFree = true; begin(.dictation)
    }
    func toggle() {
        if phase == .recording { if !handsFree { handsFree = true } else { finish() }; return }
        guard !busy else { return }
        handsFree = true; begin(.dictation)
    }
    /// `byVoice` marks a dictation started by "Ehi Verb"; `position` is where in the
    /// microphone stream its recording begins, so the words said with the phrase are kept.
    /// `withPhrase` is false when the phrase was said alone and the recording starts after it.
    func begin(_ mode: CaptureMode = .dictation, byVoice: Bool = false, from position: Int? = nil, withPhrase: Bool = true) {
        guard !busy else { return }
        if settings.speechProvider == .onDevice && !speechInstalled {
            // Already on its way: how far, and nothing else to do.
            if downloadingSpeech { hint("The speech model is still downloading (\(Int(downloadProgress * 100))%)."); return }
            page = .models; showWindow?(); notify("Download the speech model before your first dictation."); return
        }
        if settings.speechProvider == .endpoint {
            do { _ = try EndpointPolicy.validate(settings.speechEndpoint, allowRemote: settings.allowRemoteProcessing) }
            catch {
                hint(settings.allowRemoteProcessing ? "The speech server’s address needs fixing in Models." : "Remote processing is off. Turn it on in Settings, or recognise speech on this Mac.")
                notify(error.localizedDescription); return
            }
        }
        let target = TextTarget.capture(includeSelection: mode == .command)
        if target?.secure == true { hint("Dictation is disabled in this sensitive field."); return }
        // With nothing selected, or nowhere to edit, the command keys take a request instead.
        let requested = mode
        var mode = mode
        if mode == .command, let target, target.selection.isEmpty, let range = target.range, range.length == 0 { mode = .ask }
        if mode == .command, target == nil || target?.verdict == InsertionPolicy.Verdict.none, ownEditor == nil { mode = .ask }
        if mode == .command {
            // Editors such as VS Code and Sublime Text don't show their selection to Accessibility:
            // it is then read by copying it, once the keys are up (see run).
            let most = RewriteBudget.maxWords(settings.cleanupProvider)
            if let text = target?.selection, text.split(whereSeparator: \.isWhitespace).count > most { hint("Select at most \(most) words for a voice edit."); return }
            guard settings.cleanupProvider != .off else { hint("Choose a writing model in Models first."); notify("Enable a writing model in Models to use voice editing."); return }
            guard writerReady else { hint("The writing model isn’t ready. Set it up in Models."); return }
            // A field that shows its text and a cursor with nothing selected has nothing to edit. Apps
            // that hide their selection show neither, and are asked by copying once you have spoken.
            if let target, target.selection.isEmpty, let range = target.range, range.length == 0, let element = target.element,
               (TextTarget.attribute(element, kAXNumberOfCharactersAttribute) as? Int ?? 0) > 0 { hint("Select some text first."); return }
        }
        idleUnload?.cancel(); idleUnload = nil
        learner?.cancel(); learner = nil; pendingSuggestion = nil
        // The ask keys with the box still open: the new question follows on from the last ones.
        let followUp = mode == .ask && answer != nil
        if answer != nil, !followUp { answer = nil; answerTarget = nil; answerArmed = false; conversation = [] }
        // Only the ask keys themselves take questions alone; the edit keys turned into a request still act and write.
        askingOnly = requested == .ask
        pasteBox = nil; pasteCopied = false; pastedLast = false
        meetingOffer = nil
        sessionSite = mode == .command ? nil : SiteReader.site(of: target)
        if case .recording(let started) = meeting { dictationInMeeting = Date().timeIntervalSince(started) }
        sessionTerms = []; sessionCode = nil
        // A model sent away while idle comes back while you speak.
        if settings.speechProvider == .onDevice { let variant = settings.localModel; Task { [weak self] in try? await self?.speech.prepare(variant) } }
        let id = UUID(); operation = id; activeTarget = target; sessionSettings = settings; sessionLibrary = library
        stopWhenReady = false; elapsed = 0; meter.reset(); outcome = .none; keptRecording = false; notice = nil; asSaid = false
        startedByVoice = byVoice; heardSpeech = byVoice && speaking; lastSpeech = Date()
        setPhase(.authorizing)
        activeTask = Task {
            let asked = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard operation == id, !Task.isCancelled else { reset(); return }
            refreshPermissions()
            guard granted else { notify("Enable Microphone for Verb in System Settings → Privacy & Security."); status = "Microphone access is off"; outcome = .failed; reset(); return }
            // The keys came up while macOS asked for the microphone: the first time, that is no cancel.
            if stopWhenReady {
                if asked { status = "Microphone allowed. Hold the dictation keys and speak."; outcome = .hint } else { status = "Recording cancelled"; outcome = .cancelled }
                reset(); return
            }
            let audioName = id.uuidString + ".wav"
            let record = DictationRecord(id: id, appName: target?.appName ?? "Verb", bundleID: target?.bundleID ?? "", language: settings.language.rawValue, engine: settings.speechProvider == .onDevice ? settings.localModel : settings.speechModel, mode: mode, audioName: audioName, startedByVoice: byVoice && withPhrase ? true : nil)
            do {
                activeRecord = record
                if settings.retention != .none { try store.save(record) }
                try recorder.start(url: paths.audio.appendingPathComponent(audioName), deviceID: settings.microphoneID, from: position ?? preparedPosition)
                preparedPosition = nil
                recordingStarted = Date(); lastSpeech = Date(); lastCheckpoint = Date(); setPhase(.recording)
                // With the microphone already open, so no first word waits: the names already in the
                // field, and the project of an editor or a terminal.
                if mode == .dictation && settings.namesFromField, let target, let nearby = FieldContext.nearbyText(target) {
                    sessionTerms = FieldTerms.extract(from: nearby, isOrdinary: AppModel.isOrdinary)
                }
                prepareCode(mode: mode, target: target)
                // A long dictation on this Mac is written down part by part as it goes.
                if settings.speechProvider == .onDevice {
                    let vocabulary = library.vocabulary + sessionTerms.filter { term in !library.vocabulary.contains { $0.word == term } }.map { VocabularyEntry(word: $0) }
                    ahead = TranscriptAhead(id: id, variant: settings.localModel, language: settings.language, vocabulary: vocabulary)
                }
                startLivePreview()
                // While you speak, the writing model loads if it went to sleep.
                warmWriter()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak model = self] _ in
                    Task { @MainActor in
                        guard let model else { return }
                        model.elapsed = Date().timeIntervalSince(model.recordingStarted ?? Date())
                        if model.elapsed >= model.longestDictation { model.finish() }
                        else if model.startedByVoice, model.elapsed >= AppModel.longestVoiceDictation {
                            // Started by voice and never closed: perhaps a voice on TV said the phrase.
                            model.holdPaste = "A dictation started by voice ran for 30 minutes without its closing phrase, so it wasn’t pasted. It’s in History."
                            model.finish()
                        } else {
                            model.endQuietVoiceDictation(); model.endQuietHandsFree(); model.checkpoint()
                            if model.elapsed >= 29, Int(model.elapsed * 10) % 10 == 0 { model.ahead?.step(recorder: model.recorder, speech: model.speech) }
                        }
                    }
                }
            } catch { captureFailed(error) }
        }
    }
    /// The longest a dictation started by voice records without its closing phrase.
    static let longestVoiceDictation: Double = 30 * 60
    /// Ends the recording. With `tail`, the microphone stays open a quarter of a second more:
    /// the end of the last word is still on its way when the keys come up.
    func finish(tail: Bool = true) {
        guard phase == .recording, !finishing, activeRecord != nil, let id = operation else { return }
        timer?.invalidate(); timer = nil; stopLivePreview()
        guard tail else { completeRecording(id); return }
        finishing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.operation == id else { return }
            self.completeRecording(id)
        }
    }
    private func completeRecording(_ id: UUID) {
        finishing = false
        guard phase == .recording, var record = activeRecord, operation == id else { return }
        do {
            let result = recorder.stop(); record.duration = result.duration; record.voiced = result.voiced; record.handsFree = handsFree ? true : nil
            recordingProblem = result.problem
            if let silent = silentMicrophone {
                try discard(record); status = silent; outcome = .failed; notify(silent); reset(); return
            }
            // A second or more of perfect silence: the microphone is muted or not the one you speak into.
            if result.duration >= 1, result.peak < 0.0005 {
                try discard(record); status = (recorder.inputName.isEmpty ? "The microphone" : recorder.inputName) + " heard nothing. Check the microphone in Settings."
                outcome = .hint; reset(); return
            }
            // Nothing to hear: a moment's press, or quieter than −60 dBFS. Anything louder goes to
            // the speech engine, so a whisper or a quick “Sì” is written down.
            if result.duration < 0.25 || result.peak < 0.001 { try discard(record); status = "No speech detected"; outcome = .empty; reset(); return }
            activeRecord = record; run(record, id: id, target: activeTarget, selectedText: activeTarget?.selection)
        } catch { captureFailed(error) }
    }
    private func captureFailed(_ error: Error) {
        _ = recorder.stop()
        if var record = activeRecord {
            record.status = .failed; record.error = error.localizedDescription
            do { try finalizeStorage(&record, settings: sessionSettings ?? settings) } catch { notify(error.localizedDescription) }
        }
        keptRecording = activeRecord?.mode == .dictation && (activeRecord?.audioName.flatMap { paths.audioURL($0) }.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        status = "Recording failed"; outcome = .failed
        reloadHistory(); notify(error.localizedDescription); reset()
    }
    /// Escape. While you speak it cancels, a recording longer than half a minute after a second
    /// press. While the writing model works on a dictation, the words go in as said, and a second
    /// press cancels.
    func escape() {
        if phase == .polishing, rewrite == nil, let polishWait, !polishSkipped { polishSkipped = true; polishWait.end(); return }
        if phase == .recording, elapsed >= 30, !cancelArmed {
            cancelArmed = true
            disarm?.cancel()
            disarm = Task { [weak self] in try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { self?.cancelArmed = false } }
            return
        }
        cancel()
    }
    func cancel() {
        guard busy else { return }
        disarm?.cancel(); cancelArmed = false
        timer?.invalidate(); timer = nil
        if phase == .recording {
            let result = recorder.stop()
            if let record = activeRecord {
                // What was said can still be written down for a few seconds: Restore.
                if record.mode == .dictation, result.duration >= 0.4, result.voiced >= 0.12 {
                    var kept = record; kept.duration = result.duration; kept.handsFree = handsFree ? true : nil
                    keepForRestore(kept)
                } else { do { try discard(record) } catch { notify(error.localizedDescription) } }
            }
            status = "Recording cancelled"; outcome = .cancelled; reset()
        } else { setPhase(.cancelling); activeTask?.cancel() }
    }
    /// In an editor or a terminal, finds the open project and reads it in the background if
    /// it hasn't been read in the last ten minutes: the dictation takes longer than that.
    private func prepareCode(mode: CaptureMode, target: TextTarget?) {
        sessionCode = nil
        guard mode == .dictation, settings.codeNames, let target, CodeApps.isCode(target.bundleID) else { return }
        let root = CodeApps.projectRoot(pid: target.pid)
        sessionCode = (root?.path, CodeApps.terminals.contains(target.bundleID))
        guard let root else { return }
        let key = root.path
        if let known = codeProjects[key], Date().timeIntervalSince(known.read) < 600 { return }
        codeProjects[key] = CodeProject(index: codeProjects[key]?.index, read: Date())
        let keep: @MainActor (CodeSpeech.Index) -> Void = { [weak self] index in self?.codeProjects[key] = CodeProject(index: index, read: Date()) }
        Task.detached(priority: .utility) {
            let index = CodeSpeech.index(root: root)
            await keep(index)
        }
    }
    private func keepForRestore(_ record: DictationRecord) {
        dropRestorable()
        restorable = CancelledDictation(record: record, target: activeTarget, settings: sessionSettings ?? settings, library: sessionLibrary ?? library, terms: sessionTerms, code: sessionCode)
        let id = record.id
        restoreExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CancelledDictation.window * 1_000_000_000))
            guard let self, !Task.isCancelled, self.restorable?.record.id == id else { return }
            self.dropRestorable()
        }
    }
    /// × on the offer to restore: it goes now, as it would in a few seconds.
    func declineRestore() { dropRestorable(); flashOutcome?() }
    /// Restore is no longer offered. A short cancelled dictation goes for good, recording and
    /// entry; a long one stays in History as cancelled, for Retry.
    private func dropRestorable() {
        restoreExpiry?.cancel(); restoreExpiry = nil
        if var record = restorable?.record {
            if record.duration >= CancelledDictation.kept, let settings = restorable?.settings {
                record.status = .cancelled; record.error = "Cancelled. Retry it from History."
                do { try finalizeStorage(&record, settings: settings); reloadHistory() } catch { notify(error.localizedDescription) }
            } else { try? discard(record) }
        }
        restorable = nil
    }
    /// Writes down the dictation cancelled a moment ago, as if it had been finished.
    func restoreCancelled() {
        guard let kept = restorable, !busy else { return }
        restoreExpiry?.cancel(); restoreExpiry = nil; restorable = nil
        operation = kept.record.id; activeRecord = kept.record; activeTarget = kept.target
        // Remote processing turned off in the meantime stays off for it too.
        var restored = kept.settings; restored.allowRemoteProcessing = kept.settings.allowRemoteProcessing && settings.allowRemoteProcessing
        sessionSettings = restored; sessionLibrary = kept.library; sessionTerms = kept.terms; sessionCode = kept.code
        startedByVoice = kept.record.startedByVoice == true; outcome = .none; keptRecording = false
        run(kept.record, id: kept.record.id, target: kept.target)
    }
    func discard(_ record: DictationRecord) throws {
        try store.delete(record)
        if let name = record.audioName, let url = paths.audioURL(name), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        reloadHistory()
    }
    private func run(_ initial: DictationRecord, id: UUID, target: TextTarget?, selectedText: String? = nil) {
        let snapshot = sessionSettings ?? settings, words = sessionLibrary ?? library, terms = sessionTerms, code = sessionCode, site = sessionSite
        let held = holdPaste, problem = recordingProblem
        let early = ahead?.id == initial.id ? ahead : nil
        ahead = nil
        let hints = words.vocabulary + terms.filter { term in !words.vocabulary.contains { $0.word == term } }.map { VocabularyEntry(word: $0) }
        if initial.mode == .command { rewrite = .voiceEdit }
        asSaid = false; cancelArmed = false
        setPhase(.transcribing)
        // A retried entry that had been written down stays as it was if the retry fails, and isn't counted twice.
        let wasCompleted = initial.status == .completed
        let retrying = wasCompleted || initial.status == .failed || initial.status == .cancelled
        activeTask = Task {
            var record = initial
            let started = Date()
            var editedSelection: String?, copiedSelection: String?
            defer { if operation == id { reset() }; reloadHistory() }
            do {
                record.status = .processing
                record.engine = snapshot.speechProvider == .onDevice ? snapshot.localModel : snapshot.speechModel
                if snapshot.retention != .none { try store.save(record) }
                guard let name = record.audioName, let url = paths.audioURL(name), FileManager.default.fileExists(atPath: url.path) else { throw VerbError("The recording is no longer available.") }
                let result: SpeechResult
                if snapshot.speechProvider == .onDevice {
                    // What was written down while it recorded is kept; only the rest is read now.
                    let done = await early?.settle()
                    result = try await speech.transcribe(url: url, variant: snapshot.localModel, language: snapshot.language, vocabulary: hints, from: done?.offset ?? 0, prior: done?.texts ?? [], priorLanguage: done?.detected,
                                                         progress: progressReport(for: id, duration: record.duration))
                    workProgress = nil
                }
                else { result = try await client.transcribe(url: url, settings: snapshot, key: Secrets.read("speech"), vocabulary: words.vocabulary) }
                try Task.checkCancellation()
                // The phrases that started and ended the dictation are commands, not words to keep.
                let phrases = snapshot.voiceOptions.phrases(vocabulary: words.vocabulary)
                let startedByVoice = record.startedByVoice == true
                // Only a dictation that went on without the keys can end by voice; one held with the key ends when it's let go.
                let endsByVoice = startedByVoice || record.handsFree == true
                func withoutCommands(_ text: String) -> String {
                    var text = text
                    if startedByVoice { text = VoiceCommands.removingWake(from: text, using: phrases) }
                    if snapshot.voiceOptions.stopCommands && endsByVoice { text = VoiceCommands.removingEnding(from: text, using: phrases) }
                    return text
                }
                let heard = withoutCommands(result.text)
                // The dictionary applies to what is left, except the spellings it was taught for the phrases:
                // those only find the commands, and would otherwise turn ordinary words into them.
                let dictionary = withoutCommands(TextRules.corrected(heard, vocabulary: phrases.wording(words.vocabulary)))
                // A name from the field that the engine misspelled is put back, and so is an English word written the Italian way.
                let named = FieldTerms.correct(dictionary, terms: terms, isOrdinary: AppModel.isOrdinary)
                let english = record.mode == .dictation && snapshot.restoreEnglish
                    ? EnglishTerms.restore(named, lexicon: englishLexicon, preferred: Set(words.vocabulary.map(\.word) + terms), known: AppModel.isOrdinary, isEnglish: AppModel.isEnglishOnly)
                    : (text: named, changes: 0)
                // Words of the dictionary the engine spelled its own way, as Parakeet takes no hints.
                let matched = VocabularyMatch.correct(english.text, words: words.vocabulary.map(\.word) + terms, isOrdinary: AppModel.isOrdinary)
                let corrected = matched.text
                var fixes = TextRules.correctionCount(heard, vocabulary: words.vocabulary) + english.changes + matched.changes
                    + zip(dictionary.split(separator: " "), named.split(separator: " ")).filter { $0 != $1 }.count
                if record.mode == .dictation { learnWords(of: heard) }
                // Words that were only the phrases: nothing to write. When the engine wrote nothing at all, or
                // this was a retry, the recording stays for another try.
                if corrected.isEmpty, !result.text.isEmpty, !retrying {
                    try discard(record); status = "No speech detected"; outcome = .empty; return
                }
                // Nothing written, or what engines invent from silence ("The.", "Thank you."), for a
                // recording with hardly any voice in it: nothing was said.
                let voiced = record.voiced ?? 1
                if !retrying, (result.text.allSatisfy(\.isWhitespace) && voiced < 0.12) || TextRules.isInventedFromSilence(result.text, voiced: voiced) {
                    try discard(record); status = "No speech detected"; outcome = .empty; return
                }
                guard !corrected.isEmpty else { throw VerbError("No words were recognized.") }
                record.rawText = heard; record.language = result.language
                // Persist the raw transcript BEFORE any optional rewriting.
                if snapshot.retention != .none { try store.save(record) }
                var output = corrected
                var warning: String? = problem, note: String?
                // Snippets fill in their date, time and clipboard now; the cursor mark waits for the paste.
                var snippets = words.snippets.map { snippet -> Snippet in
                    var filled = snippet
                    filled.expansion = SnippetVariables.fill(snippet.expansion, clipboard: { NSPasteboard.general.string(forType: .string) })
                    return filled
                }
                // In an editor or a terminal, spoken names become code, kept like snippets so a writing model can't touch them.
                if record.mode == .dictation, let code {
                    let index = code.root.flatMap { codeProjects[$0]?.index }
                    snippets += CodeSpeech.replacements(in: corrected, index: index, mentionPaths: code.paths, isOrdinary: AppModel.isOrdinary).map { Snippet(trigger: $0.spoken, expansion: $0.code) }
                }
                let exactSnippet = snippets.first { TextRules.canonical($0.trigger) == TextRules.canonical(corrected) }
                var usedSnippets: [Snippet] = exactSnippet.map { [$0] } ?? []
                if record.mode == .ask {
                    try await ask(corrected, record: &record, target: target, settings: snapshot, library: words, started: started)
                    return
                }
                if record.mode == .command {
                    setPhase(.polishing)
                    var selection = selectedText ?? ""
                    if selection.isEmpty, let target { selection = try await inserter.copySelection(for: target) ?? ""; copiedSelection = selection }
                    // Nothing selected after all: a request.
                    if selection.isEmpty { try await ask(corrected, record: &record, target: target, settings: snapshot, library: words, started: started); return }
                    let most = RewriteBudget.maxWords(snapshot.cleanupProvider)
                    guard selection.split(whereSeparator: \.isWhitespace).count <= most else { try discard(record); status = "Select at most \(most) words for a voice edit."; outcome = .hint; return }
                    if snapshot.cleanupProvider == .local { try await writer.start() }
                    output = try await client.edit(text: corrected, style: .natural, vocabulary: words.vocabulary, settings: snapshot, key: Secrets.read("cleanup"), instruction: corrected, selection: selection)
                    record.rawText = selection; editedSelection = selection
                } else if let exactSnippet { output = exactSnippet.expansion }
                else {
                    let choice = snapshot.styleChoice(for: record.bundleID, site: site), style = choice.style
                    // Instant rules first; the writing model only when the policy and the words call for it.
                    let cleaned = style == .verbatim ? corrected : TextRules.joiningSpelledLetters(SpokenNumbers.inText(TextRules.quickClean(corrected, language: result.language), language: result.language))
                    let protected = TextRules.protect(cleaned, snippets: snippets)
                    usedSnippets = snippets.indices.filter { protected.text.contains(protected.replacements[$0].0) }.map { snippets[$0] }
                    fixes += max(0, corrected.split(whereSeparator: \.isWhitespace).count - cleaned.split(whereSeparator: \.isWhitespace).count)
                    output = protected.text
                    // An app with a style of its own is refined every time, unless the policy is Never.
                    let useModel = snapshot.cleanupPolicy.usesModel(wordsCallForIt: TextRules.needsRefinement(cleaned), appStyle: choice.own ? style : nil)
                    let resting = writerRest.map { $0.until > Date() && $0.writer == snapshot.writerIdentity } ?? false
                    // A model on this Mac known not to be there is as good as none: no wait, no warning.
                    let missing = snapshot.cleanupProvider == .local && (!writer.available || (!writerModels.isEmpty && !writerModels.contains(snapshot.cleanupModel)))
                    if useModel && snapshot.cleanupProvider != .off && style != .verbatim && !resting && !missing {
                        setPhase(.polishing)
                        // The names read from the field stay on this Mac: a remote model gets your dictionary only.
                        // Only the entries this text needs: a shorter prompt, read sooner.
                        let text = protected.text, vocabulary = VocabularyMatch.relevant(snapshot.writingStaysOnMac ? hints : words.vocabulary, to: text)
                        let custom = snapshot.stylePrompt(for: record.bundleID, site: site)
                        let polish = Task { () throws -> String in
                            if snapshot.cleanupProvider == .local { try await self.writer.start() }
                            return try await self.cleanLongText(text, style: style, vocabulary: vocabulary, settings: snapshot, custom: custom)
                        }
                        // A model that doesn't answer in time, or that Escape skips, gives way to the words as said.
                        let wait = PolishWait(); polishWait = wait; polishSkipped = false
                        let answer = await withTaskCancellationHandler { await wait.wait(for: polish, seconds: snapshot.cleanupProvider.deadline(words: text.split(whereSeparator: \.isWhitespace).count)) }
                                                                     onCancel: { polish.cancel(); Task { @MainActor in wait.end() } }
                        polishWait = nil
                        if answer == nil { polish.cancel() }
                        try Task.checkCancellation()
                        do {
                            guard let answer else { throw CancellationError() }
                            output = try answer.get()
                            _ = try protected.restore(output)
                            // A clean-up that changed a number, a name or a "not", or answered instead, gives way to the words as said.
                            if let finding = CleanupGuard.check(said: protected.text, cleaned: output, vocabulary: words.vocabulary.map(\.word), names: AppModel.properNames(in: protected.text)) {
                                output = protected.text; note = finding.message
                            }
                        } catch {
                            output = protected.text; asSaid = true
                            if !polishSkipped {
                                writerRest = (Date().addingTimeInterval(180), snapshot.writerIdentity)
                                warning = answer == nil ? AppModel.writerTooSlow : "AI cleanup unavailable. Kept your original transcript. " + error.localizedDescription + " " + AppModel.writerResting
                            }
                        }
                    }
                    // As above, the spellings taught for the phrases stay out of the words.
                    output = TextRules.corrected(output, vocabulary: phrases.wording(words.vocabulary))
                    if style != .verbatim { output = TextRules.commandPunctuation(output, language: result.language) }
                    if style == .lowercase { output = TextRules.chatCase(output, keep: Set(words.vocabulary.map(\.word) + terms).union(AppModel.properNames(in: output))) }
                    output = try protected.restore(output)
                }
                try Task.checkCancellation()
                guard operation == id else { return }
                // A formatted snippet goes in as formatted text, and so do the writing model's lists where
                // the app keeps formatting; in a chat they go in as plain words. History keeps the plain words.
                let own = target?.pid == ProcessInfo.processInfo.processIdentifier
                let format: PasteFormat? = record.mode == .dictation && !own && snapshot.formatForApp && RichText.hasFormatting(output) ? PasteFormat.choose(bundleID: record.bundleID, site: site, code: CodeApps.isCode(record.bundleID)) : nil
                let formatted = usedSnippets.contains(where: \.isFormatted) || format == .rich, plainly = formatted || format == .plain
                var pasted = plainly ? RichText.plain(fromMarkdown: output) : output
                fixes += usedSnippets.count
                // Spaces and capitals as the text around the cursor asks.
                if record.mode == .dictation, snapshot.fitToField, let target,
                   let context = FieldContext.read(target) ?? hotkeys.typing.before(in: target.pid).map({ FieldContext(before: $0, after: "") }) {
                    // Names keep their capital, "Marco" and "Rosa" too, though they are also words.
                    let keep = Set(words.vocabulary.map(\.word) + terms).union(AppModel.properNames(in: pasted))
                    // Code and the Verbatim style keep their casing; only the spaces fit.
                    let casing = !CodeApps.isCode(target.bundleID) && snapshot.style(for: record.bundleID) != .verbatim
                    pasted = FieldFormatting.adjust(pasted, before: context.before, after: context.after, isOrdinary: AppModel.isOrdinary, keep: keep, casing: casing)
                }
                let plain = SnippetVariables.placeCursor(in: plainly ? RichText.plain(fromMarkdown: output) : output).text
                let (text, cursorBack) = SnippetVariables.placeCursor(in: pasted)
                var html: String?
                if formatted {
                    let body = RichText.html(fromMarkdown: output.trimmingCharacters(in: .whitespaces)).replacingOccurrences(of: String(SnippetVariables.cursorMark), with: "")
                    html = (text.hasPrefix(" ") ? "&nbsp;" : "") + body + (text.hasSuffix(" ") ? "&nbsp;" : "")
                }
                output = plain
                record.text = output; record.status = .completed; record.error = warning ?? note; record.processingSeconds = Date().timeIntervalSince(started)
                if record.mode == .dictation { record.fixes = fixes }
                latestText = output; latestOriginal = record.rawText
                setPhase(.inserting)
                if target?.pid == ProcessInfo.processInfo.processIdentifier, let editor = ownEditor {
                    // Verb's own fields, the notepad and the welcome's practice sheet among them, take
                    // the words directly; a voice edit only where its selection still is.
                    if let editedSelection, editor.selectedText != editedSelection { record.delivery = TextInserter.keptMoved }
                    else {
                        editor.insert(text); record.delivery = editor.delivery
                        if editor.isNote { sheetWriting = SheetWriting(mode: record.mode, handsFree: handsFree, text: text) }
                    }
                } else {
                    // Kept rather than pasted: a dictation that may not have been meant, or one that
                    // ended with the screen locked.
                    let hold = held ?? (screenLocked || screensAsleep ? "The screen locked during the dictation, so it wasn’t pasted. It’s in History." : nil)
                    if let hold { record.delivery = TextInserter.keptInHistory; notify(hold) }
                    else if target == nil, retrying { record.delivery = TextInserter.retried }
                    else {
                        let entry = record.id, app = target?.appName ?? ""
                        record.delivery = snapshot.autoInsert ? try await inserter.insert(text, html: html, target: target, requireSelection: record.mode == .command, copied: copiedSelection,
                                                                                       late: { self.pasteTakenLate(entry, app: app) }) : "Ready to copy"
                    }
                }
                if cursorBack > 0, record.delivery.hasPrefix("Paste sent"), let target { inserter.moveCursorBack(cursorBack, in: target) }
                if record.delivery.hasPrefix("Paste sent"), let target { hotkeys.typing.wrote(cursorBack > 0 ? String(text.dropLast(cursorBack)) : text, in: target.pid) }
                // The words you retype in the next moments can teach the dictionary.
                if record.mode == .dictation, record.delivery.hasPrefix("Paste sent"), snapshot.learnFromCorrections, let target, let location = target.range?.location {
                    watchCorrections(pasted: text, target: target, location: location)
                }
                // A retry from History writes there: its text is in the entry, and on the paste key.
                status = record.delivery; outcome = record.delivery == TextInserter.retried ? .delivered : Outcome.of(delivery: record.delivery)
                // Nowhere for it to go: the text waits in the overlay's box, with Copy.
                if outcome == .copyOnly, record.mode == .dictation, !output.isEmpty { pasteBox = output; pasteCopied = false; answerArmed = true }
                if let warning { notify(warning) }
                try finalizeStorage(&record, settings: snapshot)
                if DictationStats.counts(record), !wasCompleted { stats.add(record); try? JSONStore.save(stats, to: paths.stats); noticeRecurringNames() }
                // The sound of success is for text that went in.
                if settings.soundFeedback, outcome == .delivered { NSSound(named: "Pop")?.play() }
                if outcome == .delivered, record.mode == .dictation { coachDelivered(bundleID: record.bundleID) }
            } catch {
                let cancelled = Task.isCancelled
                // A request's card says what went wrong, or goes with the request.
                if record.mode == .ask, answer != nil {
                    if cancelled { closeAnswer() } else { answer?.streaming = false; answer?.problem = error.localizedDescription; answerArmed = true }
                }
                if wasCompleted {
                    // The entry keeps the text it had; only the reason the retry failed is shown.
                    if snapshot.retention != .none { try? store.save(initial) }
                    status = cancelled ? "Cancelled" : record.mode == .command ? "Couldn't apply the edit" : "Couldn't finish dictation"; outcome = cancelled ? .cancelled : .failed
                    if !cancelled { notify(error.localizedDescription) }
                    return
                }
                record.status = cancelled ? .cancelled : .failed
                record.error = cancelled ? "Processing was cancelled." : error.localizedDescription
                if !record.rawText.isEmpty, record.mode != .command { record.text = record.rawText; latestText = record.rawText; latestOriginal = record.rawText }
                do { try finalizeStorage(&record, settings: snapshot) } catch { notify(error.localizedDescription) }
                keptRecording = record.mode != .command && snapshot.retention != .none && record.audioName != nil
                status = cancelled ? (keptRecording ? "Cancelled · recording saved" : "Cancelled") : record.mode == .command ? "Couldn't apply the edit" : record.mode == .ask ? "Couldn't answer" : "Couldn't finish dictation"; outcome = cancelled ? .cancelled : .failed
                if !cancelled { notify(error.localizedDescription + (keptRecording ? " " + AppModel.savedForRetry : "")) }
            }
        }
    }
    /// What the engine calls as a recording past a minute is written down, for the percentage the overlay shows.
    private func progressReport(for id: UUID, duration: Double) -> (@Sendable (Double) -> Void)? {
        guard duration > 60 else { return nil }
        return { [weak self] fraction in self?.progressed(fraction, operation: id) }
    }
    /// Long work came a little further, as heard from the engine's own thread.
    nonisolated private func progressed(_ fraction: Double, operation id: UUID) {
        Task { @MainActor () -> Void in if operation == id { workProgress = fraction } }
    }
    private func cleanLongText(_ text: String, style: WritingStyle, vocabulary: [VocabularyEntry], settings: Settings, custom: String? = nil) async throws -> String {
        // Bound context and output size for long dictations: parts of about 600 words, cut where
        // sentences end and joined the way the text was. Short dictations use one call.
        let parts = TextRules.parts(of: text)
        defer { workProgress = nil }
        let key = Secrets.read("cleanup"), personal = settings.personalInstructions, client = client
        // A model on this Mac reads one part at a time; a server or a subscription reads three at once.
        guard settings.cleanupProvider != .local, parts.count > 1 else {
            var result = ""
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                if parts.count > 1 { workProgress = Double(index) / Double(parts.count) }
                result += part.joiner + (try await client.edit(text: part.text, style: style, vocabulary: VocabularyMatch.relevant(vocabulary, to: part.text), settings: settings, key: key, customStyle: custom, personal: personal))
            }
            return result
        }
        var edited = [String](repeating: "", count: parts.count), finished = 0
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func start() {
                guard next < parts.count else { return }
                let index = next, part = parts[index].text
                group.addTask { (index, try await client.edit(text: part, style: style, vocabulary: VocabularyMatch.relevant(vocabulary, to: part), settings: settings, key: key, customStyle: custom, personal: personal)) }
                next += 1
            }
            for _ in 0..<3 { start() }
            while let (index, text) = try await group.next() {
                edited[index] = text; finished += 1
                workProgress = Double(finished) / Double(parts.count)
                start()
            }
        }
        return zip(parts, edited).map { $0.joiner + $1 }.joined()
    }
    static let othersMissing = "Recording your microphone only, so the others won’t be in the notes. To include a call, allow Verb in System Settings → Privacy & Security → Screen & System Audio Recording."
    static let writerTooSlow = "The writing model took too long, so the words went in as said. It rests for three minutes; dictations meanwhile go in as said."
    static let writerResting = "It rests for three minutes; dictations meanwhile go in as said."
    static let meetingNotWritten = "A meeting couldn’t be written down. Its recordings are kept: retry it in Notes."
    static let accessibilityLost = "Verb’s keys stopped: Accessibility is off. Allow it again in System Settings. If Verb is already on there, remove it with − and add it again."
    /// Added to an error when the recording stayed for Retry.
    static let savedForRetry = "The recording is saved. Retry it from History."
    private func finalizeStorage(_ record: inout DictationRecord, settings snapshot: Settings) throws {
        // A dictation that failed or was cancelled keeps its recording for Retry, whatever the audio
        // setting; it expires with the other recordings.
        let retryable = record.status == .failed || record.status == .cancelled
        if snapshot.retention == .none || (!snapshot.keepAudio && !retryable) {
            if let name = record.audioName, let url = paths.audioURL(name), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            record.audioName = nil
        }
        if snapshot.retention != .none { try store.save(record) }
    }
    func reset() {
        finishing = false; holdPaste = nil; recordingProblem = nil; silentMicrophone = nil
        stopLivePreview(); liveTask?.cancel(); liveTask = nil; liveText = ""; liveTentative = ""
        timer?.invalidate(); timer = nil; activeTask = nil; operation = nil; activeRecord = nil; activeTarget = nil; sessionSettings = nil; sessionLibrary = nil; meter.reset(); handsFree = false; rewrite = nil
        // What was read from the field belongs to this dictation only.
        sessionTerms = []; sessionCode = nil; pressedWhileBusy = false
        // A session that ended before it recorded, as when microphone access was refused, lets go of the microphone too.
        recorder.release(); preparedPosition = nil
        setPhase(.idle)
        if let from = dictationInMeeting, case .recording(let started) = meeting { meetingDictations.append(from...max(from, Date().timeIntervalSince(started) + 1)) }
        dictationInMeeting = nil
        ahead?.cancel(); ahead = nil; silenceLeft = nil; sessionSite = nil
        scheduleIdleUnload()
    }
    /// After a while without dictating, the models leave memory. The speech model stays while
    /// Verb listens for its name, which needs it.
    func scheduleIdleUnload() {
        idleUnload?.cancel()
        let minutes = settings.idleMinutes
        guard services, minutes > 0 else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.freeMemory()
        }
    }
    /// Takes the speech and writing models out of memory now. The next dictation loads them
    /// again while you speak.
    func freeMemory() async {
        guard !busy else { scheduleIdleUnload(); return }
        // A model still loading or at work, as for a meeting being written down, is asked again in a minute.
        if !voiceListening, !(await speech.unload()) {
            idleUnload = Task { [weak self] in try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { await self?.freeMemory() } }
        }
        if settings.cleanupProvider == .local, writer.available { await client.unloadLocal(model: settings.cleanupModel) }
        lastWarmUp = .distantPast
    }
    func retry(_ record: DictationRecord) {
        guard !busy else { return }
        guard record.mode != .command else { notify("For a new voice edit, select the original text and record your instruction again."); return }
        operation = UUID(); sessionSettings = settings; sessionLibrary = library
        run(record, id: operation!, target: nil)
    }
    func pasteLast() {
        guard !busy, !latestText.isEmpty else { return }
        // Pasted where you clicked: the box that held it has done its job.
        pasteBox = nil; pasteCopied = false
        // Verb's own fields take it directly, as they take a dictation.
        if let editor = ownEditor {
            editor.insert(latestText); status = editor.delivery; outcome = .delivered; pastedLast = true
            flashOutcome?(); return
        }
        let target = TextTarget.capture(), text = latestText
        setPhase(.inserting)
        activeTask = Task {
            defer { reset() }
            do { status = try await inserter.insert(text, target: target, late: { self.pasteTakenLate(nil, app: target?.appName ?? "") }); outcome = Outcome.of(delivery: status); pastedLast = outcome == .delivered }
            catch { if !Task.isCancelled { notify(error.localizedDescription); status = "Couldn't paste"; outcome = .failed } }
        }
    }
    /// An app slower than a second took the paste after all: the note that said it hadn't is put right.
    private func pasteTakenLate(_ id: UUID?, app: String) {
        let note = TextInserter.notTaken(app), sent = "Paste sent to \(app)"
        if phase == .idle, status == note { status = sent; outcome = .delivered }
        guard let id, var record = try? store.all().first(where: { $0.id == id }), record.delivery == note else { return }
        record.delivery = sent
        do { try store.save(record); reloadHistory() } catch { notify(error.localizedDescription) }
    }
    func copy(_ text: String) { inserter.copy(text); status = "Copied to clipboard"; Announcer.say(lang("Copied", "Copiato")) }
    /// The copy shortcut: the last dictation goes on the clipboard, and the overlay says so.
    func copyLast() {
        guard !busy else { return }
        // The box open with a dictation that found no field: the copy keys copy it.
        if pasteBox != nil { copyPasteBox(); return }
        guard !latestText.isEmpty else { return }
        copy(latestText); outcome = .copied; pastedLast = false
        flashOutcome?()
    }
    func delete(_ record: DictationRecord) {
        guard !busy else { return }
        do { try store.delete(record); reloadHistory() } catch { notify(error.localizedDescription) }
        // Gone from the Mac means gone from Home and from the paste and copy keys too.
        if record.text == latestText || record.rawText == latestOriginal { refreshLatest() }
    }
    /// The last dictation, for Home and the paste and copy keys, as History holds it now.
    private func refreshLatest() {
        latestText = history.first(where: { !$0.text.isEmpty })?.text ?? ""
        latestOriginal = history.first(where: { !$0.rawText.isEmpty })?.rawText ?? ""
    }
    func clearHistory() {
        guard !busy else { return }
        do { for record in history { try store.delete(record) }; latestText = ""; latestOriginal = ""; reloadHistory() } catch { notify(error.localizedDescription) }
        // Saved audio includes the meetings' recordings; their notes stay.
        pruneMeetings(all: true)
    }
    func saveEdited(_ record: DictationRecord, text: String) {
        var updated = record; updated.text = text
        do { try store.save(updated); reloadHistory() } catch { notify(error.localizedDescription); return }
        // The last dictation, edited, is what the paste and copy keys give.
        if record.text == latestText { latestText = text }
    }
    /// Asks for a recording, then transcribes it.
    func importAudio() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.prompt = lang("Import", "Importa"); panel.message = lang("Choose a recording to write down.", "Scegli una registrazione da trascrivere."); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importAudio(from: source)
    }
    /// Transcribes a recording chosen in the panel or dropped on History, as if it had just been
    /// dictated with no text field in front. It works on a copy kept with the other recordings,
    /// so it can be played back and retried like one.
    func importAudio(from source: URL) {
        guard !busy else { return }
        let id = UUID(), name = id.uuidString + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)
        do {
            // A drop can be any file, and AVAudioFile's own errors are numeric codes. MIDI, for one, is audio it cannot read.
            let unreadable = VerbError("Verb can't read this file as audio. Try an m4a, mp3, wav or aiff recording.")
            guard (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .audio) == true, let file = try? AVAudioFile(forReading: source) else { throw unreadable }
            guard file.length > 0 else { throw VerbError("This recording contains no audio.") }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration <= longestDictation else { throw VerbError(settings.speechProvider == .endpoint ? "Import a recording up to 20 minutes long." : "Import a recording up to 4 hours long.") }
            try FileManager.default.copyItem(at: source, to: paths.audio.appendingPathComponent(name))
            operation = id; sessionSettings = settings; sessionLibrary = library
            run(DictationRecord(id: id, duration: duration, appName: "Audio import", engine: settings.localModel, audioName: name), id: id, target: nil)
        } catch { notify(error.localizedDescription) }
    }
    /// The dictation keys were for another shortcut: fn held a moment before an arrow or Delete,
    /// ⌃⌥ before a window manager's key or N. With nothing said yet, the dictation goes without a
    /// word in the overlay, a sound or a change of volume.
    func abandonUnspoken() {
        guard phase == .recording, !handsFree, !startedByVoice, !heardSpeech, elapsed < (activeMode == .command ? 3 : 1.5) else { return }
        timer?.invalidate(); timer = nil; stopLivePreview()
        _ = recorder.stop()
        if let record = activeRecord { try? discard(record) }
        outcome = .none; reset()
    }
    func abandonUnspokenVoiceEdit() { if activeMode == .command { abandonUnspoken() } }
    /// Opens the microphone as the dictation keys go down, so the words said during the short wait
    /// before the dictation starts are kept.
    private func prepareMicrophone() {
        guard !busy, microphoneGranted, settings.speechProvider != .onDevice || speechInstalled else { return }
        recorder.prepare(deviceID: settings.microphoneID)
        preparedPosition = recorder.position
    }
    /// The screen locked or went to sleep during a dictation: it ends there, and waits in History.
    private func endForAbsence() {
        guard phase == .recording else { return }
        holdPaste = "The screen locked during the dictation, so it wasn’t pasted. It’s in History."
        finish(tail: false)
    }
    func applyTransform(_ index: Int) {
        // ⌃⌥ held a moment too long before the key has started a voice edit: nothing has been
        // said yet, so the transform wins.
        if phase == .recording, activeMode == .command, !heardSpeech, elapsed < 3 { cancel() }
        guard !busy, library.transforms.indices.contains(index) else { return }
        if ownEditor != nil { transformNote(index); return }
        guard let target = TextTarget.capture(includeSelection: true) else { hint("Select some text first."); return }
        guard !target.secure else { hint("Dictation is disabled in this sensitive field."); return }
        guard settings.cleanupProvider != .off else { hint("Choose a writing model in Models first."); notify("Enable a writing model in Models to use voice editing."); return }
        guard writerReady else { hint("The writing model isn’t ready. Set it up in Models."); return }
        let transform = library.transforms[index], snapshot = settings, id = UUID()
        operation = id; rewrite = .transform(transform.name); setPhase(.polishing)
        activeTask = Task {
            defer { reset(); reloadHistory() }
            do {
                var selection = target.selection, copied: String?
                if selection.isEmpty { selection = try await inserter.copySelection(for: target) ?? ""; copied = selection }
                guard !selection.isEmpty else { status = "Select some text first."; outcome = .hint; return }
                let most = RewriteBudget.maxWords(snapshot.cleanupProvider)
                guard selection.split(whereSeparator: \.isWhitespace).count <= most else { status = "Select at most \(most) words."; outcome = .hint; return }
                if snapshot.cleanupProvider == .local { try await writer.start() }
                let output = try await client.edit(text: selection, style: .natural, vocabulary: library.vocabulary, settings: snapshot, key: Secrets.read("cleanup"), instruction: transform.instruction, selection: selection)
                try Task.checkCancellation()
                latestOriginal = selection; latestText = output
                let delivery = snapshot.autoInsert ? try await inserter.insert(output, target: target, requireSelection: true, copied: copied, late: { self.pasteTakenLate(id, app: target.appName) }) : "Ready to copy"
                status = delivery; outcome = Outcome.of(delivery: delivery)
                if snapshot.retention != .none { try store.save(DictationRecord(id: id, rawText: selection, text: output, appName: target.appName, bundleID: target.bundleID, engine: snapshot.cleanupModel, mode: .command, status: .completed, delivery: delivery)) }
            } catch {
                if Task.isCancelled { status = "Transform cancelled"; outcome = .cancelled }
                else { notify(error.localizedDescription); status = "Couldn't apply the transform"; outcome = .failed }
            }
        }
    }
    /// A transform run in one of Verb's own fields, as the open note: on the selection, or on
    /// everything in it when nothing is selected.
    func transformNote(_ index: Int) {
        guard !busy, library.transforms.indices.contains(index), let editor = ownEditor else { return }
        guard settings.cleanupProvider != .off else { hint("Choose a writing model in Models first."); return }
        if editor.selectedText.isEmpty { editor.selectAll() }
        let selection = editor.selectedText
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hint(editor.isNote ? "Write something in the note first." : "Write something first."); return }
        let transform = library.transforms[index], snapshot = settings, id = UUID()
        operation = id; rewrite = .transform(transform.name); setPhase(.polishing)
        activeTask = Task {
            defer { reset() }
            do {
                if snapshot.cleanupProvider == .local { try await writer.start() }
                let output = try await client.edit(text: selection, style: .natural, vocabulary: library.vocabulary, settings: snapshot, key: Secrets.read("cleanup"), instruction: transform.instruction, selection: selection)
                try Task.checkCancellation()
                // Put back only where the selection still is; otherwise it waits as the last dictation, and the clipboard stays yours.
                if editor.isEditing, editor.selectedText == selection { editor.insert(output); status = editor.delivery; outcome = .delivered }
                else { status = TextInserter.keptMoved; outcome = .copyOnly }
                latestOriginal = selection; latestText = output
            } catch {
                if Task.isCancelled { status = "Transform cancelled"; outcome = .cancelled }
                else { notify(error.localizedDescription); status = "Couldn't apply the transform"; outcome = .failed }
            }
        }
    }
    /// The keys for the actions and the transforms, as the settings and the library hold them.
    /// A clash with another app is said once; it goes away when the keys work again.
    func configureKeys() {
        guard services else { return }
        do {
            try hotkeys.configure(settings.keyOptions, transforms: library.transforms.map(\.keys))
            // While Settings listens, nothing was registered yet: a clash is only known once it stops.
            if !hotkeys.suspended, notice?.hasSuffix("Choose another shortcut in Settings.") == true { notice = nil }
        } catch { notify(error.localizedDescription) }
    }
    /// A short message in the overlay, where you are looking, for something that couldn't start.
    /// The window's banner is kept for what has to be settled in Verb.
    func hint(_ message: String) {
        guard !busy else { return }
        status = message; outcome = .hint
        flashOutcome?()
        Announcer.say(lang.message(message))
    }
    func downloadSpeech() {
        guard !downloadingSpeech, !downloadingWriter, !busy else { return }
        let variant = settings.localModel
        // Room for the whole model first, rather than a full disk part way through.
        if let size = try? SpeechCatalog.model(variant).downloadBytes, let free = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < size + 200_000_000 {
            notify("This model needs \(lang.size(size)) free, and the disk has \(lang.size(free)). Free some space first."); return
        }
        downloadingSpeech = true; downloadProgress = 0; downloadStopped = false; downloadBaseline = nil
        downloadTask = Task {
            defer { downloadingSpeech = false; downloadBaseline = nil }
            do { try await speech.install(variant) { [weak model = self] progress, text in Task { @MainActor in model?.downloaded(progress, text) } }; speechInstalled = speech.installed(settings.localModel); refreshListening() }
            catch { downloadFailed(error) }
        }
    }
    /// Progress from a download, and where it began, for the time it still needs.
    private func downloaded(_ progress: Double, _ text: String) {
        downloadProgress = progress; downloadStatus = text
        if downloadBaseline == nil, progress > 0 { downloadBaseline = (Date(), progress) }
    }
    /// A download that stopped: on purpose it is no error, and either way the next try carries on from there.
    private func downloadFailed(_ error: Error) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { downloadStatus = "Download stopped"; downloadStopped = true; return }
        let code = (error as? URLError)?.code
        if [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code) {
            notify("The download stopped: the Mac is offline or the connection dropped. Try again, and it carries on where it stopped."); downloadStopped = true; return
        }
        if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError || (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOSPC) {
            notify("The disk is full. Free some space, then try again: the download carries on where it stopped."); downloadStopped = true; return
        }
        notify(error.localizedDescription)
    }
    func downloadWriter() {
        guard !downloadingWriter, !downloadingSpeech, !busy else { return }; downloadingWriter = true; downloadProgress = 0; downloadStatus = "Starting the local writing engine…"; downloadStopped = false; downloadBaseline = nil
        downloadTask = Task {
            defer { downloadingWriter = false; downloadBaseline = nil }
            // Ollama keeps what it has fetched: a pull tried again carries on.
            do { try await writer.start(); try await client.pull(settings.cleanupModel) { [weak model = self] progress, text in Task { @MainActor in model?.downloaded(progress, AppModel.pullStatus(text)) } }; writerModels = try await client.localModels(); downloadStatus = "Writing model ready" }
            catch { downloadFailed(error) }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    /// Ollama's own words for a download, as people would say them.
    static func pullStatus(_ status: String) -> String {
        switch status {
        case "pulling manifest": return "Getting the download ready…"
        case "verifying sha256 digest": return "Checking the download…"
        case "writing manifest", "removing any unused layers": return "Finishing the download…"
        case "success": return "Writing model ready"
        default: return status.hasPrefix("pulling ") ? "Downloading the writing model…" : status
        }
    }
    func exportHistory() {
        let panel = NSSavePanel(); panel.prompt = lang("Export", "Esporta"); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = lang("Verb-history.json", "Verb-cronologia.json")
        if panel.runModal() == .OK, let url = panel.url { do { try JSONStore.save(history, to: url) } catch { notify(error.localizedDescription) } }
    }
    func shutdown() {
        // A dictation being recorded is kept, as it would be after a crash; one being written stops
        // and waits in History too.
        if phase == .recording { keepInterruptedRecording() } else { cancel() }
        dropRestorable(); stopMeetingForQuit()
        ducker.restore(); downloadTask?.cancel(); harnessTask?.cancel(); harnessTestTask?.cancel(); voiceCheck?.cancel(); recorder.stopListening(); writer.stop()
    }
    /// Quitting while recording: the audio so far is closed and saved, and History offers Retry.
    private func keepInterruptedRecording() {
        timer?.invalidate(); timer = nil; stopLivePreview()
        let result = recorder.stop()
        guard var record = activeRecord else { return }
        record.duration = result.duration; record.voiced = result.voiced
        record.handsFree = handsFree ? true : nil
        record.status = .failed; record.error = "Verb was closed during this dictation. Retry the saved audio."
        if (sessionSettings ?? settings).retention != .none { try? store.save(record) }
        else if let name = record.audioName, let url = paths.audioURL(name) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Voice

    /// Keeps the microphone open between dictations exactly when "Ehi Verb" can work: the
    /// setting is on, the microphone is allowed and the speech model is on this Mac, which
    /// does all the listening. Called often; it costs nothing when nothing changed.
    func refreshListening() {
        guard services, listeningReady else { return }
        let present = !screenLocked && !screensAsleep
        let trying: Bool = { if case .listening = voiceTrial { return true }; return false }()
        let wanted = (settings.voiceOptions.wakeWord && present || trying) && microphoneGranted && speechInstalled
        if wanted {
            do {
                try recorder.listen(deviceID: settings.microphoneID)
                // Listening works again: the notice that said it had stopped is out of date.
                if listenProblem != nil, notice?.hasPrefix("Voice activation is paused.") == true { notice = nil }
                listenProblem = nil
            }
            catch {
                // Said once, not every few seconds.
                if listenProblem != error.localizedDescription { listenProblem = error.localizedDescription; notify("Voice activation is paused. " + error.localizedDescription) }
            }
        } else if recorder.listening { recorder.stopListening() }
        voiceListening = wanted && settings.voiceOptions.wakeWord && present && recorder.running
    }

    private func heard(_ moment: SpeechMoment) {
        switch moment.event {
        case .started, .continuing: speaking = true; lastSpeech = Date(); if phase == .recording { heardSpeech = true }
        case .ended(let segment):
            speaking = false; lastSpeech = Date()
            if phase == .recording { updateLive(commitAt: segment.end) }
        }
        route(moment)
    }
    /// Idle, every utterance may be "Ehi Verb". Recording hands-free, every pause may follow
    /// "Ehi Verb stop". Holding the key, there is nothing to listen for.
    private func route(_ moment: SpeechMoment) {
        guard !moment.window.isEmpty else { return }
        if case .listening(let kind) = voiceTrial { if case .ended = moment.event { runTrial(kind, moment) }; return }
        if phase == .idle, settings.voiceOptions.wakeWord { check(moment) }
        else if phase == .recording, handsFree, case .ended = moment.event, (sessionSettings ?? settings).voiceOptions.stopCommands { check(moment) }
    }
    /// One check at a time; while one runs, only the newest moment waits its turn.
    private func check(_ moment: SpeechMoment) {
        guard voiceCheck == nil else { queuedMoment = moment; return }
        let variant = settings.localModel, language = settings.language, recording = phase == .recording, id = operation
        let phrases = (recording ? sessionSettings ?? settings : settings).voiceOptions.phrases(vocabulary: (recording ? sessionLibrary ?? library : library).vocabulary)
        // A wake phrase must open the utterance; a stop command is read in context.
        let samples = recording ? moment.window : moment.utterance
        voiceCheck = Task { [weak self] in
            let text = (try? await self?.speech.recognize(samples: samples, variant: variant, language: language)) ?? ""
            guard let self else { return }
            self.voiceCheck = nil
            self.voiceReader.phrases = phrases
            self.act(on: self.voiceReader.read(text, after: moment.event, recording: recording), operation: id, moment: moment)
            if let next = self.queuedMoment { self.queuedMoment = nil; self.route(next) }
        }
    }
    private func act(on decision: VoiceCommands.Decision, operation id: UUID?, moment: SpeechMoment) {
        switch decision {
        case .none: break
        case .wake(let position):
            guard phase == .idle, settings.voiceOptions.wakeWord else { return }
            // A phrase said alone ends where the recording starts, so none of it is in the words.
            let alone: Bool = { if case .ended(let segment) = moment.event { return position == segment.end }; return false }()
            handsFree = true
            begin(.dictation, byVoice: true, from: position, withPhrase: !alone)
        case .finish: if phase == .recording, operation == id { finish() }
        case .cancel: if phase == .recording, operation == id { cancel() }
        }
    }
    /// A hands-free dictation started with the keys finishes on the silence chosen in Settings,
    /// with the last seconds counted down in the overlay.
    func endQuietHandsFree() {
        let limit = Double((sessionSettings ?? settings).handsFreeSilence)
        guard limit > 0, handsFree, !startedByVoice, phase == .recording, activeMode == .dictation else { if silenceLeft != nil { silenceLeft = nil }; return }
        let left = limit - (speaking ? 0 : Date().timeIntervalSince(lastSpeech))
        let shown = left > 0 && left <= 3 ? Int(left.rounded(.up)) : nil
        if silenceLeft != shown { silenceLeft = shown }
        if left <= 0 { finish() }
    }
    /// A dictation started by voice has no key to let go of: it finishes by itself after 20
    /// seconds of silence, and is never thrown away on its own.
    func endQuietVoiceDictation() {
        guard startedByVoice, phase == .recording, !speaking, Date().timeIntervalSince(lastSpeech) >= 20 else { return }
        // A long one that ends on silence, not on its closing phrase, may have been a voice on TV.
        if elapsed >= 300 { holdPaste = "A dictation started by voice ran for over 5 minutes and ended on silence, so it wasn’t pasted. It’s in History." }
        finish()
    }
    // MARK: Trying the phrases

    /// Listens for the next utterance and shows what the engine wrote, so a misheard phrase can
    /// be seen, and taught.
    func startVoiceTrial(_ kind: VoiceTrial.Kind) {
        guard !busy else { return }
        guard microphoneGranted else { requestMicrophone(); return }
        guard speechInstalled else { notify("Download the speech model in Models to try the phrase."); return }
        trialTimeout?.cancel()
        voiceTrial = .listening(kind)
        refreshListening()
        trialTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.voiceTrial == .listening(kind) else { return }
            self.voiceTrial = .silent(kind); self.refreshListening()
        }
    }
    func endVoiceTrial() { trialTimeout?.cancel(); voiceTrial = .idle; refreshListening() }
    private func runTrial(_ kind: VoiceTrial.Kind, _ moment: SpeechMoment) {
        guard case .ended(let segment) = moment.event else { return }
        trialTimeout?.cancel()
        let variant = settings.localModel, language = settings.language, samples = moment.utterance
        let phrases = settings.voiceOptions.phrases(vocabulary: library.vocabulary)
        Task { [weak self] in
            let text = (try? await self?.speech.recognize(samples: samples, variant: variant, language: language)) ?? ""
            guard let self, self.voiceTrial == .listening(kind) else { return }
            let decision = VoiceCommands.decide(text, after: .ended(segment), recording: kind == .finish, using: phrases)
            let understood: Bool
            if kind == .wake, case .wake = decision { understood = true } else { understood = kind == .finish && decision != .none }
            let lesson = understood ? nil : VoiceCommands.lesson(in: text, closing: kind == .finish, using: phrases)
            if let lesson, kind == .wake, Self.isOrdinary(lesson.heard) { self.voiceTrial = .common(kind, text: text, lesson: lesson) }
            else { self.voiceTrial = .heard(kind, text: text, understood: understood, lesson: lesson) }
            self.refreshListening()
        }
    }
    /// Words that the spelling checker knows, every one of them, in Italian or English: "ever", "e verbi".
    static func isOrdinary(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.allSatisfy { knows($0, "it") || knows($0, "en") }
    }
    /// The names of people, places and organisations in a text, as Natural Language finds them
    /// from the sentence around them.
    static func properNames(in text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { for part in text[range].split(separator: " ") { names.insert(String(part)) } }
            return true
        }
        return names
    }
    /// An English word that isn't also Italian.
    static func isEnglishOnly(_ word: String) -> Bool { knows(word, "en") && !knows(word, "it") }
    private static var spelling: [String: Bool] = [:]
    /// Whether the spell checker knows the word in the language; asked once per word.
    static func knows(_ word: String, _ language: String) -> Bool {
        let key = language + ":" + word
        if let known = spelling[key] { return known }
        if spelling.count > 20_000 { spelling = [:] }
        let known = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        spelling[key] = known
        return known
    }
    /// Counts the words of a dictation, for recognising English words written the Italian way.
    private func learnWords(of text: String) {
        for token in text.split(whereSeparator: { !$0.isLetter }) where token.count >= 4 { englishLexicon[token.lowercased(), default: 0] += 1 }
    }
    /// The phrase a lesson stands for: "Ehi Verb", or "Ehi Verb stop" for a closing one. The
    /// dictionary keeps "Ehi"; with a language, it is shown as said in it.
    func meaning(of lesson: VoiceCommands.Lesson, _ t: Lang? = nil) -> String {
        (t?("Hey ", "Ehi ") ?? "Ehi ") + settings.voiceOptions.spokenName + (lesson.command.map { " " + $0 } ?? "")
    }
    /// Adds what the engine wrote to the dictionary as the phrase, so from now on it counts as the phrase.
    func teachVoiceTrial() {
        let kind: VoiceTrial.Kind, lesson: VoiceCommands.Lesson
        switch voiceTrial {
        case .heard(let tried, _, false, let learned?): kind = tried; lesson = learned
        case .common(let tried, _, let learned): kind = tried; lesson = learned
        default: return
        }
        let meaning = meaning(of: lesson)
        if !library.vocabulary.contains(where: { TextRules.canonical($0.heardAs) == TextRules.canonical(lesson.heard) }) {
            var updated = library
            updated.vocabulary.append(VocabularyEntry(word: meaning, heardAs: lesson.heard))
            library = updated
        }
        voiceTrial = .taught(kind, heard: lesson.heard, meaning: meaning)
    }

    // MARK: Live preview

    /// Four times a second while you speak, Verb reads the part of the recording that has not
    /// settled; at each pause, or once it passes three seconds, that part settles. Only the preview uses it: the text pasted at the end
    /// comes from the whole recording.
    private func startLivePreview() {
        liveText = ""; liveTentative = ""; liveOffset = 0; pendingLiveCommit = nil
        guard settings.livePreview, speechInstalled else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateLive(commitAt: nil) } }
    }
    private func stopLivePreview() { liveTimer?.invalidate(); liveTimer = nil; pendingLiveCommit = nil }
    private func updateLive(commitAt position: Int?) {
        guard phase == .recording, liveTimer != nil else { return }
        if let position { pendingLiveCommit = max(pendingLiveCommit ?? 0, recorder.takeOffset(ofStream: position)) }
        guard liveTask == nil else { return }
        var commit = pendingLiveCommit; pendingLiveCommit = nil
        let (samples, end) = recorder.take(from: liveOffset)
        // No pause for three seconds: settle the older words at the quietest moment, so the part read again stays short.
        if commit == nil, let cut = LivePreviewCut.settle(samples[...]) { commit = liveOffset + cut }
        let start = liveOffset, upTo = min(commit ?? end, end), count = upTo - start
        // Less than a fifth of a second is nothing to read yet.
        guard count >= 16000 / 5 else { if commit != nil { liveOffset = max(liveOffset, upTo) }; return }
        let slice = Array(samples.prefix(count)), variant = settings.localModel, language = settings.language, id = operation
        liveTask = Task { [weak self] in
            let text = (try? await self?.speech.recognize(samples: slice, variant: variant, language: language)) ?? ""
            guard let self else { return }
            self.liveTask = nil
            guard self.operation == id, self.phase == .recording else { return }
            if commit != nil {
                if !text.isEmpty { self.liveText += (self.liveText.isEmpty ? "" : " ") + text }
                self.liveOffset = start + count; self.liveTentative = ""
            } else { self.liveTentative = text }
            if self.pendingLiveCommit != nil { self.updateLive(commitAt: nil) }
        }
    }
    /// The preview as shown: the dictionary applied, the phrases that start and end the dictation left out.
    var livePreview: (settled: String, tentative: String) {
        let vocabulary = (sessionLibrary ?? library).vocabulary
        let phrases = (sessionSettings ?? settings).voiceOptions.phrases(vocabulary: vocabulary), wording = phrases.wording(vocabulary)
        var settled = TextRules.corrected(liveText, vocabulary: wording), tentative = TextRules.corrected(liveTentative, vocabulary: wording)
        if startedByVoice { settled.isEmpty ? (tentative = VoiceCommands.removingWake(from: tentative, using: phrases)) : (settled = VoiceCommands.removingWake(from: settled, using: phrases)) }
        if tentative.isEmpty { settled = VoiceCommands.removingEnding(from: settled, using: phrases) } else { tentative = VoiceCommands.removingEnding(from: tentative, using: phrases) }
        return (settled, tentative)
    }

    // MARK: Writing model

    /// Loads the local writing model and reads its instructions once, so the next dictation
    /// that needs it waits for neither. Skipped when it was done in the last 20 minutes.
    func warmWriter() {
        guard services, settings.cleanupProvider == .local, settings.cleanupPolicy != .never, writerModels.contains(settings.cleanupModel),
              Date().timeIntervalSince(lastWarmUp) > Double(settings.idleMinutes > 0 ? min(20, settings.idleMinutes) : 20) * 60 else { return }
        lastWarmUp = Date()
        let snapshot = settings, vocabulary = library.vocabulary
        Task { [weak self] in
            guard let self else { return }
            try? await self.writer.start()
            await self.client.warmUp(settings: snapshot, vocabulary: vocabulary)
        }
    }
}
