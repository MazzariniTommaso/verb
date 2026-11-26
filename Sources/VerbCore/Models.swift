import Foundation
import CryptoKit

public enum SpeechProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice, endpoint
    public var id: String { rawValue }
    public var title: String { self == .onDevice ? "On this Mac" : "Hosted / custom server" }
}
public enum CleanupProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, harness, endpoint, off
    public var id: String { rawValue }
    /// How long a dictation waits for the writing model before it goes in as said: a model on
    /// this Mac answers in seconds, a server in a few more, a subscription CLI in up to half a
    /// minute. Longer dictations get longer.
    public func deadline(words: Int) -> Double {
        switch self {
        case .local: return 12 + Double(words) * 0.05
        case .endpoint: return 15 + Double(words) * 0.05
        case .harness: return 45 + Double(words) * 0.1
        case .off: return 0
        }
    }
    public var title: String { switch self { case .local: return "Local · Ollama"; case .harness: return "My subscriptions · CLI"; case .endpoint: return "Hosted / custom server"; case .off: return "No AI cleanup" } }
}
/// How much text one voice edit or transform takes, and the room the writing model is given for
/// its answer, which can be longer than the text, as a translation is.
public enum RewriteBudget {
    /// The most words one rewrite takes. A model on this Mac holds its whole context in memory,
    /// so it takes fewer than a server or a subscription.
    public static func maxWords(_ provider: CleanupProvider) -> Int { provider == .local ? 3000 : 12000 }
    /// Tokens for the answer: about two and a half a word, never fewer than a short answer needs.
    public static func outputTokens(words: Int) -> Int { min(32_768, max(2048, words * 5 / 2)) }
    /// The local model's context: the usual size, or a larger one for a long text. Ollama loads the
    /// model again when this changes, so there are just two sizes.
    public static func localContext(words: Int) -> Int { words * 4 + 1024 <= 8192 ? 8192 : 16384 }
}

/// The language you speak: detected, or one of those the speech models know. Raw values are
/// ISO codes.
public enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, it, en, es, fr, de, pt, nl, pl, ru, uk, cs, sk, sl, hr, bg, ro, hu, el, sv, da, fi, et, lv, lt, mt
    case ar, fa, hi, ja, ko, ms, th, tr, vi, zh, cantonese = "yue", filipino = "fil", indonesian = "id", macedonian = "mk"
    public var id: String { rawValue }
    public var title: String { self == .auto ? "Detect automatically" : Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue }
}
public enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `custom` is an app's own: the words come from what you wrote for it. `lowercase` is the
    /// way people write to friends, and needs no writing model.
    case natural, casual, formal, verbatim, custom, lowercase
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var detail: String {
        switch self {
        case .natural: return "Your words, with fillers and clear self-corrections cleaned up."
        case .casual: return "Conversational messages, with lighter punctuation."
        case .formal: return "Careful grammar and complete sentences. Preserve your meaning."
        case .verbatim: return "Keep the speech engine's wording. Skip AI rewriting."
        case .custom: return "Follow the user's own description of how to write here."
        case .lowercase: return "Small letters and light punctuation, as in a chat with friends."
        }
    }
    /// The styles every app can have; `custom` needs words written for one app.
    public static let standard: [WritingStyle] = [.natural, .casual, .lowercase, .formal, .verbatim]
    /// A style that reshapes every dictation, so the writing model is asked even for a short one.
    public var reshapes: Bool { [.casual, .formal, .custom].contains(self) }
}
public enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en", italian = "it"
    public var id: String { rawValue }
}
public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark
    public var id: String { rawValue }
}
public struct InterfacePreferences: Codable, Equatable, Sendable {
    public var language: InterfaceLanguage = .english
    public var appearance: Appearance = .automatic
    public init() {}
    // Tolerates missing keys so later additions never discard these choices.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(InterfaceLanguage.self, forKey: .language) ?? .english
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .automatic
    }
}
/// Dictation by voice: "Ehi Verb" starts it, "Ehi Verb stop" ends it.
public struct VoicePreferences: Codable, Equatable, Sendable {
    /// Listen for the wake phrase between dictations. Off until chosen, because it keeps the
    /// microphone open.
    public var wakeWord = false
    /// Finish with "Ehi Verb stop", "Ehi Verb invia" and the like. The command never reaches the text.
    public var stopCommands = true
    /// The words said after "Ehi", as many as wanted. The first is the one shown.
    public var names = ["Verb"]
    /// The words said after the name to finish, and to throw the recording away.
    public var finishWords = VoiceCommands.standardFinishes
    public var cancelWords = VoiceCommands.standardCancels
    public init() {}
    // Tolerates missing keys so later additions never discard these choices.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wakeWord = try values.decodeIfPresent(Bool.self, forKey: .wakeWord) ?? false
        stopCommands = try values.decodeIfPresent(Bool.self, forKey: .stopCommands) ?? true
        names = try values.decodeIfPresent([String].self, forKey: .names) ?? ["Verb"]
        finishWords = try values.decodeIfPresent([String].self, forKey: .finishWords) ?? VoiceCommands.standardFinishes
        cancelWords = try values.decodeIfPresent([String].self, forKey: .cancelWords) ?? VoiceCommands.standardCancels
    }
    /// The names as they are matched: one word each, "Verb" when none is left.
    public var spokenNames: [String] {
        let words = names.compactMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) }
        return words.isEmpty ? ["Verb"] : words
    }
    /// The first name, the one shown in "Ehi Verb".
    public var spokenName: String { spokenNames[0] }
    public func phrases(vocabulary: [VocabularyEntry]) -> VoiceCommands.Phrases {
        VoiceCommands.Phrases(names: spokenNames, finishWords: finishWords, cancelWords: cancelWords, vocabulary: vocabulary)
    }
}
/// When the writing model reworks a dictation. Transforms and voice edits always use it.
public enum CleanupPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every dictation, the slowest.
    case always
    /// Only when the words call for it: a spoken correction ("anzi", "actually"), a list, or a
    /// long passage. Otherwise the text goes in at once.
    case whenNeeded
    /// Never: the recognized words, the dictionary and the quick rules only.
    case never
    public var id: String { rawValue }
    /// Whether a dictation goes to the writing model. Under When needed, an app with a style
    /// of its own that reshapes the words is refined every time, or its style would show only
    /// in long or corrected dictations. Never means never.
    public func usesModel(wordsCallForIt: Bool, appStyle: WritingStyle?) -> Bool {
        switch self {
        case .always: return true
        case .whenNeeded: return wordsCallForIt || appStyle?.reshapes == true
        case .never: return false
        }
    }
}
/// How the overlay looks while Verb records and works.
public enum OverlayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The full capsule: the red dot, the voice, the time, the key to finish and a stop button.
    case classic
    /// A small pill: the red dot and the voice.
    case pill
    /// The voice alone, its dots in the accent colour; called Voice in the interface.
    case ink
    /// One circle with the voice inside it, the smallest.
    case dot
    /// A slim bar with the red dot, the time and the voice.
    case bar
    /// A black island at the notch: symbols beside it, words below it.
    case notch
    public var id: String { rawValue }
}
public enum Retention: Int, Codable, CaseIterable, Identifiable, Sendable {
    case none = 0, day = 1, week = 7, month = 30, forever = -1
    public var id: Int { rawValue }
    public var title: String { switch self { case .none: return "Don't keep history"; case .day: return "24 hours"; case .week: return "7 days"; case .month: return "30 days"; case .forever: return "Until I delete it" } }
}
/// `command` edits the selection; `ask` is a request made with nothing selected.
public enum CaptureMode: String, Codable, Sendable { case dictation, command, ask }
public enum SessionStatus: String, Codable, Sendable { case recorded, processing, completed, failed, cancelled }

/// Modifier keys, as Verb stores them. The app maps them to the Mac's own flags.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
    /// The symbols in the order macOS writes them: "fn ⌃ ⌥ ⇧ ⌘".
    public var symbols: String {
        [(Self.function, "fn"), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { contains($0.0) }.map(\.1).joined(separator: " ")
    }
    public var count: Int { rawValue.nonzeroBitCount }
}

/// A key, or keys, Verb listens for anywhere on the Mac: modifiers held on their own ("fn",
/// "⌃ ⌥"), or a key with modifiers ("⇧ ⌘ C", "F5").
public struct KeyBinding: Codable, Hashable, Sendable {
    public var modifiers: KeyModifiers
    /// The key pressed with the modifiers; nil when the modifiers alone are the binding.
    public var keyCode: UInt32?
    /// How it is written, as it was pressed: "fn", "⌃ ⌥", "⇧ ⌘ C".
    public var label: String
    public init(modifiers: KeyModifiers, keyCode: UInt32? = nil, label: String) { self.modifiers = modifiers; self.keyCode = keyCode; self.label = label }
    public var isModifierOnly: Bool { keyCode == nil }

    public static let fn = KeyBinding(modifiers: [.function], label: "fn")
    public static let controlOption = KeyBinding(modifiers: [.control, .option], label: "⌃ ⌥")
    public static let optionCommand = KeyBinding(modifiers: [.option, .command], label: "⌥ ⌘")
    public static let shiftCommandC = KeyBinding(modifiers: [.shift, .command], keyCode: 8, label: "⇧ ⌘ C")
    public static let controlCommandC = KeyBinding(modifiers: [.control, .command], keyCode: 8, label: "⌃ ⌘ C")
    public static let controlCommandV = KeyBinding(modifiers: [.control, .command], keyCode: 9, label: "⌃ ⌘ V")
    public static let controlOptionN = KeyBinding(modifiers: [.control, .option], keyCode: 45, label: "⌃ ⌥ N")

    /// F1 to F20, which can be used on their own.
    public static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    /// The digits 1 to 9, which the first transforms get with ⌃⌥.
    public static let digitKeys: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    public static func transformDigit(_ index: Int) -> KeyBinding {
        KeyBinding(modifiers: [.control, .option], keyCode: digitKeys[index], label: "⌃ ⌥ \(index + 1)")
    }
    /// The same keys, however their names were written.
    public func sameKeys(as other: KeyBinding) -> Bool { modifiers == other.modifiers && keyCode == other.keyCode }

    public enum Problem: Equatable, Sendable {
        /// A key needs ⌃, ⌥ or ⌘, or must be a function key: otherwise it is typing.
        case needsModifier
        /// One modifier on its own is part of typing and of countless shortcuts.
        case singleModifier
        /// fn works only on its own.
        case functionWithKey
        /// Taken by macOS or by every app: ⌘C, ⌘V, ⌘Q, ⌘Space…
        case reserved
        /// This action is pressed, not held: it needs a key.
        case needsKey
        /// Space turns a held dictation hands-free, so it can't also be the key that holds one.
        case spaceIsHandsFree
    }
    /// Why the binding can't be used, or nil when it can. `hold` is for actions that last while
    /// the keys are down (dictation, voice edit), which may use modifiers alone.
    public func problem(hold: Bool) -> Problem? {
        guard let keyCode else {
            guard hold else { return .needsKey }
            if modifiers == [.function] || modifiers.count >= 2 { return nil }
            return .singleModifier
        }
        if modifiers.contains(.function) { return .functionWithKey }
        if modifiers.isEmpty || modifiers == [.shift] { return Self.functionKeys.contains(keyCode) ? nil : .needsModifier }
        if hold, keyCode == 49 { return .spaceIsHandsFree }
        // ⌘ with A S Z X C V Q W H M, Tab, Space; ⌃ Space switches the input source; ⌃⌘ with F,
        // Q and Space are full screen, the lock screen and emoji in every app.
        if modifiers == [.command], [0, 1, 6, 7, 8, 9, 12, 13, 4, 46, 48, 49].contains(keyCode) { return .reserved }
        if modifiers == [.control], keyCode == 49 { return .reserved }
        if modifiers == [.control, .command], [3, 12, 49].contains(keyCode) { return .reserved }
        return nil
    }
    /// Well-known apps that use these keys for something of their own. Verb's keys work in
    /// every app, so choosing them takes them from those apps.
    public var knownUsers: [String] {
        guard let keyCode else { return [] }
        let known: [(KeyModifiers, UInt32, [String])] = [
            ([.shift, .command], 8, ["Chrome", "Finder", "TextEdit", "Xcode"]),
            ([.control, .command], 9, ["Word", "Excel"]),
            ([.option, .command], 9, ["Finder"]),
            ([.shift, .option, .command], 9, ["Mail", "Notes", "Pages"]),
            ([.option, .command], 8, ["Pages", "Safari"]),
            ([.control, .command], 2, ["macOS"]),
        ]
        return known.first { $0.0 == modifiers && $0.1 == keyCode }?.2 ?? []
    }
    /// VoiceOver's own keys: held, or with a key, they are its commands.
    public var usesVoiceOverKeys: Bool { modifiers.isSuperset(of: [.control, .option]) }
}

/// The keys for Verb's actions. Any of them can be left without keys: choosing keys that
/// another action or a transform had takes them away from it.
public struct KeyBindings: Codable, Equatable, Sendable {
    /// Held to dictate. With it held, Space switches to hands-free.
    public var dictation: KeyBinding? = .fn
    /// Held, with text selected, to say how to change it.
    public var voiceEdit: KeyBinding? = .controlOption
    /// Held to ask a question: the answer comes in the overlay's box.
    public var ask: KeyBinding? = .optionCommand
    /// Puts the last dictation on the clipboard.
    public var copyLast: KeyBinding? = .controlCommandC
    /// Pastes the last dictation where the cursor is.
    public var pasteLast: KeyBinding? = .controlCommandV
    /// Opens and closes the notepad.
    public var notepad: KeyBinding? = .controlOptionN
    /// Pressed once to start a hands-free dictation and once more to finish it, for anyone who
    /// can't hold keys down. None until chosen.
    public var handsFree: KeyBinding?
    public init() {}
    private enum CodingKeys: String, CodingKey { case dictation, voiceEdit, ask, copyLast, pasteLast, notepad, handsFree }
    // A missing entry gets its standard keys; one left empty on purpose stays empty.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ standard: KeyBinding) throws -> KeyBinding? {
            guard values.contains(key) else { return standard }
            return try values.decodeNil(forKey: key) ? nil : values.decode(KeyBinding.self, forKey: key)
        }
        dictation = try read(.dictation, .fn); voiceEdit = try read(.voiceEdit, .controlOption); ask = try read(.ask, .optionCommand)
        copyLast = try read(.copyLast, .controlCommandC); pasteLast = try read(.pasteLast, .controlCommandV)
        notepad = try read(.notepad, .controlOptionN)
        handsFree = try values.decodeIfPresent(KeyBinding.self, forKey: .handsFree)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dictation, forKey: .dictation); try values.encode(voiceEdit, forKey: .voiceEdit); try values.encode(ask, forKey: .ask)
        try values.encode(copyLast, forKey: .copyLast); try values.encode(pasteLast, forKey: .pasteLast)
        try values.encode(notepad, forKey: .notepad)
        try values.encodeIfPresent(handsFree, forKey: .handsFree)
    }

    public subscript(target: KeyTarget) -> KeyBinding? {
        get {
            switch target { case .dictation: return dictation; case .voiceEdit: return voiceEdit; case .ask: return ask; case .copyLast: return copyLast; case .pasteLast: return pasteLast; case .notepad: return notepad; case .handsFree: return handsFree; case .transform: return nil }
        }
        set {
            switch target { case .dictation: dictation = newValue; case .voiceEdit: voiceEdit = newValue; case .ask: ask = newValue; case .copyLast: copyLast = newValue; case .pasteLast: pasteLast = newValue; case .notepad: notepad = newValue; case .handsFree: handsFree = newValue; case .transform: break }
        }
    }
    /// Who has these keys now, if anyone.
    public static func owner(of binding: KeyBinding, keys: KeyBindings, transforms: [Transform]) -> KeyTarget? {
        if let action = KeyTarget.actions.first(where: { keys[$0]?.sameKeys(as: binding) == true }) { return action }
        return transforms.first { $0.keys?.sameKeys(as: binding) == true }.map { .transform($0.id) }
    }
    /// Gives the keys to `target`, or takes its keys away when `binding` is nil. Whoever had the
    /// same keys loses them, so one set of keys never does two things.
    public static func assign(_ binding: KeyBinding?, to target: KeyTarget, keys: inout KeyBindings, transforms: inout [Transform]) {
        if let binding {
            for action in KeyTarget.actions where action != target && keys[action]?.sameKeys(as: binding) == true { keys[action] = nil }
            for index in transforms.indices where KeyTarget.transform(transforms[index].id) != target && transforms[index].keys?.sameKeys(as: binding) == true { transforms[index].keys = nil }
        }
        if case .transform(let id) = target { if let index = transforms.firstIndex(where: { $0.id == id }) { transforms[index].keys = binding } }
        else { keys[target] = binding }
    }
}

/// Something that can have keys: one of Verb's actions, or a transform.
public enum KeyTarget: Hashable, Sendable {
    case dictation, voiceEdit, ask, copyLast, pasteLast, notepad, handsFree
    case transform(UUID)
    public static let actions: [KeyTarget] = [.dictation, .handsFree, .voiceEdit, .ask, .copyLast, .pasteLast, .notepad]
    /// Held for as long as it lasts, so modifiers alone can be its keys.
    public var hold: Bool { self == .dictation || self == .voiceEdit || self == .ask }
}

/// Totals over every dictation. They are kept apart from History, so its clean-ups don't
/// shrink them.
public struct DictationStats: Codable, Equatable, Sendable {
    public var words = 0
    public var seconds: Double = 0
    public var dictations = 0
    /// Words and seconds of voice with the pauses left out, from the dictations that measured them.
    public var voicedWords = 0
    public var voicedSeconds: Double = 0
    /// Words per day, keyed "2026-09-26".
    public var days: [String: Int] = [:]
    /// Words per app.
    public var apps: [String: Int] = [:]
    /// Hesitations and repeats taken out, dictionary corrections and snippets: what Verb put right.
    public var fixes = 0
    public init() {}
    public init(words: Int, seconds: Double, dictations: Int) { self.words = words; self.seconds = seconds; self.dictations = dictations }
    public init(history: [DictationRecord]) { self.init(); for record in history { add(record) } }
    // Tolerates missing keys: a total saved without one starts it from zero.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        words = try values.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        dictations = try values.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        voicedWords = try values.decodeIfPresent(Int.self, forKey: .voicedWords) ?? 0
        voicedSeconds = try values.decodeIfPresent(Double.self, forKey: .voicedSeconds) ?? 0
        days = try values.decodeIfPresent([String: Int].self, forKey: .days) ?? [:]
        apps = try values.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
        fixes = try values.decodeIfPresent(Int.self, forKey: .fixes) ?? 0
    }
    /// What counts: dictations that gave text. Not voice edits, transforms or imported recordings.
    public static func counts(_ record: DictationRecord) -> Bool {
        record.mode == .dictation && record.status == .completed && !record.text.isEmpty && record.duration > 0 && record.appName != "Audio import"
    }
    public mutating func add(_ record: DictationRecord) {
        guard Self.counts(record) else { return }
        let count = record.wordCount
        words += count; seconds += record.duration; dictations += 1
        if let voiced = record.voiced, voiced > 0 { voicedWords += count; voicedSeconds += voiced }
        days[Self.day(record.createdAt), default: 0] += count
        apps[record.appName, default: 0] += count
        fixes += record.fixes ?? 0
    }
    /// Words per minute of voice, pauses left out once there are 20 seconds of it measured;
    /// before that, pauses included. Nil until there are 20 seconds to go on.
    public var wordsPerMinute: Double? {
        if voicedSeconds >= 20 { return Double(voicedWords) / (voicedSeconds / 60) }
        return seconds >= 20 ? Double(words) / (seconds / 60) : nil
    }
    /// Whether the words per minute leave the pauses out.
    public var leavesOutPauses: Bool { voicedSeconds >= 20 }
    /// The average most often quoted for typing on a computer keyboard.
    public static let typingWordsPerMinute = 40.0

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Days in a row with a dictation up to today, or up to yesterday before today's first one;
    /// and the longest run there has been.
    public func streak(today: Date = Date(), calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let active = Set(days.filter { $0.value > 0 }.keys)
        guard !active.isEmpty else { return (0, 0) }
        var current = 0
        var day = calendar.startOfDay(for: today)
        if !active.contains(Self.day(day, calendar: calendar)), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        while active.contains(Self.day(day, calendar: calendar)), let previous = calendar.date(byAdding: .day, value: -1, to: day) { current += 1; day = previous }
        var longest = 0, run = 0, last: Date?
        for key in active.sorted() {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { continue }
            if let last, let next = calendar.date(byAdding: .day, value: 1, to: last), calendar.isDate(next, inSameDayAs: date) { run += 1 } else { run = 1 }
            longest = max(longest, run); last = date
        }
        return (current, max(longest, current))
    }
    /// Words dictated in the calendar month of `date`.
    public func words(inMonthOf date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let prefix = String(format: "%04d-%02d-", parts.year ?? 0, parts.month ?? 0)
        return days.filter { $0.key.hasPrefix(prefix) }.map(\.value).reduce(0, +)
    }
    /// The apps with the most words, most first.
    public func topApps(_ count: Int) -> [(name: String, words: Int)] {
        apps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(count).map { ($0.key, $0.value) }
    }
}
public struct Settings: Codable, Equatable, Sendable {
    public var version = 1
    public var speechProvider: SpeechProvider = .onDevice
    public var localModel = SpeechCatalog.defaultID
    public var language: DictationLanguage = .auto
    public var cleanupProvider: CleanupProvider = .local
    public var cleanupModel = "qwen3:4b-instruct-2507-q4_K_M"
    public var speechEndpoint = "https://api.groq.com/openai/v1/audio/transcriptions"
    public var speechModel = "whisper-large-v3-turbo"
    public var cleanupEndpoint = "https://api.groq.com/openai/v1/chat/completions"
    public var hostedCleanupModel = ""
    /// The writing model in use, as one value: a model that failed rests until another is chosen.
    public var writerIdentity: String { [cleanupProvider.rawValue, cleanupModel, hostedCleanupModel, cleanupEndpoint, harnessOptions.provider.rawValue, harnessOptions.model].joined(separator: "|") }
    /// Whether the writing model runs on this Mac: Verb's own Ollama, or a server on this Mac.
    /// Only then do the names read from the field go to it.
    public var writingStaysOnMac: Bool { cleanupProvider == .local || (cleanupProvider == .endpoint && EndpointPolicy.isOnThisMac(cleanupEndpoint)) }
    public var allowRemoteProcessing = false
    public var style: WritingStyle = .natural
    /// What you wrote for the apps whose style is Custom, by bundle identifier.
    public var appPrompts: [String: String]?
    public var stylePrompts: [String: String] {
        get { appPrompts ?? [:] }
        set { appPrompts = newValue.isEmpty ? nil : newValue }
    }
    public var appStyles: [String: WritingStyle] = ["com.apple.MobileSMS": .casual, "net.whatsapp.WhatsApp": .casual, "com.tinyspeck.slackmacgap": .casual, "com.apple.mail": .formal, "com.microsoft.Outlook": .formal, "com.apple.Terminal": .verbatim, "com.googlecode.iterm2": .verbatim]
    public var retention: Retention = .month
    public var keepAudio = true
    public var autoInsert = true
    public var soundFeedback = true
    public var microphoneID = ""
    public var onboardingComplete = false
    /// Where the welcome was left, and the gestures already tried on its practice sheet: a
    /// welcome interrupted by a quit carries on from there.
    public var welcomeStep: Int?
    public var welcomeTried: [Int]?
    // The groups below are optional on disk: a settings file without one keeps every other preference.
    public var harness: HarnessPreferences?
    public var harnessOptions: HarnessPreferences {
        get { harness ?? HarnessPreferences() }
        set { harness = newValue }
    }
    public var interface: InterfacePreferences?
    public var interfaceOptions: InterfacePreferences {
        get { interface ?? InterfacePreferences() }
        set { interface = newValue }
    }
    public var cleanup: CleanupPolicy?
    public var cleanupPolicy: CleanupPolicy {
        get { cleanup ?? .whenNeeded }
        set { cleanup = newValue }
    }
    /// Show the words in a card above the overlay while they are spoken.
    public var preview: Bool?
    public var livePreview: Bool {
        get { preview ?? true }
        set { preview = newValue }
    }
    public var voice: VoicePreferences?
    public var voiceOptions: VoicePreferences {
        get { voice ?? VoicePreferences() }
        set { voice = newValue }
    }
    public var overlay: OverlayStyle?
    public var overlayStyle: OverlayStyle {
        get { overlay ?? .pill }
        set { overlay = newValue }
    }
    /// Without it, the keys are fn, ⌃⌥, ⌃⌘C, ⌃⌘V and ⌃⌥N.
    public var keys: KeyBindings?
    public var keyOptions: KeyBindings {
        get { keys ?? KeyBindings() }
        set { keys = newValue }
    }
    /// Turn the Mac's sound down while dictating. On unless turned off.
    public var duck: Bool?
    public var duckAudio: Bool {
        get { duck ?? true }
        set { duck = newValue }
    }
    /// Fit a dictation to the text around the cursor: spaces, capitals, a full stop mid-sentence.
    public var fieldFit: Bool?
    public var fitToField: Bool {
        get { fieldFit ?? true }
        set { fieldFit = newValue }
    }
    /// Notice the words you retype after a dictation, and offer them to the dictionary.
    public var learn: Bool?
    public var learnFromCorrections: Bool {
        get { learn ?? true }
        set { learn = newValue }
    }
    /// The folder of the notes and meeting notes; empty for Verb's own.
    public var notesFolder: String?
    public var notesPath: String {
        get { notesFolder ?? "" }
        set { notesFolder = newValue.isEmpty ? nil : newValue }
    }
    /// Use the names already written in the field as hints for recognition.
    public var fieldHints: Bool?
    public var namesFromField: Bool {
        get { fieldHints ?? true }
        set { fieldHints = newValue }
    }
    /// Put back English words the engine wrote the Italian way ("mercio" for merge).
    public var english: Bool?
    public var restoreEnglish: Bool {
        get { english ?? true }
        set { english = newValue }
    }
    /// In editors and terminals, turn spoken names into the project's code and files.
    public var code: Bool?
    public var codeNames: Bool {
        get { code ?? true }
        set { code = newValue }
    }
    /// With no microphone chosen, the Mac's own before Bluetooth headphones. Off unless asked:
    /// headphones are closer to the mouth, though they play in call quality while you dictate.
    public var builtInMic: Bool?
    public var preferBuiltInMic: Bool {
        get { builtInMic ?? false }
        set { builtInMic = newValue }
    }
    /// Minutes without dictating before the models leave memory; 0 keeps them loaded.
    public var idle: Int?
    public var idleMinutes: Int {
        get { idle ?? 30 }
        set { idle = newValue }
    }
    /// A style for each kind of place: emails, work chats, chats with friends, everything else.
    /// An app or a site with a style of its own keeps it.
    public var categories: [String: WritingStyle]?
    public var categoryStyles: [AppCategory: WritingStyle] {
        get { (categories ?? Self.standardCategories).reduce(into: [:]) { result, entry in if let kind = AppCategory(rawValue: entry.key) { result[kind] = entry.value } } }
        set { categories = newValue.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value } }
    }
    public static let standardCategories: [String: WritingStyle] = [AppCategory.email.rawValue: .formal, AppCategory.personal.rawValue: .casual]
    /// About you, in your words: your name, your role, how you sign. Every rewrite and answer reads it.
    public var instructions: String?
    public var personalInstructions: String {
        get { instructions ?? "" }
        set { instructions = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(newValue.prefix(1000)) }
    }
    /// Seconds of silence that finish a hands-free dictation started with the keys; 0 never.
    public var silence: Int?
    public var handsFreeSilence: Int {
        get { silence ?? 0 }
        set { silence = newValue }
    }
    /// With the notch style, the island stays at the notch between dictations: pointed at, it says
    /// how to start, and a click on it dictates.
    public var notchDrop: Bool?
    public var notchAtRest: Bool {
        get { notchDrop ?? true }
        set { notchDrop = newValue }
    }
    /// The window's sidebar with its icons alone, as you left it. It changes only when you ask.
    public var sidebarIcons: Bool?
    public var sidebarCollapsed: Bool {
        get { sidebarIcons ?? false }
        set { sidebarIcons = newValue }
    }
    /// Offer to record a call when an app for calls starts using the microphone.
    public var detectMeetings: Bool?
    public var meetingDetection: Bool {
        get { detectMeetings ?? true }
        set { detectMeetings = newValue }
    }
    /// The kind of notes a meeting gets, and the kinds you described.
    public var meetingKind: String?
    public var meetingTemplate: String {
        get { meetingKind ?? MeetingTemplate.general }
        set { meetingKind = newValue }
    }
    public var meetingKinds: [MeetingTemplate]?
    public var customMeetingTemplates: [MeetingTemplate] {
        get { meetingKinds ?? [] }
        set { meetingKinds = newValue.isEmpty ? nil : newValue }
    }
    /// A request with the command keys reads the text on screen, for a writing model on this Mac.
    public var askScreen: Bool?
    public var askReadsScreen: Bool {
        get { askScreen ?? true }
        set { askScreen = newValue }
    }
    /// Lists and bold from the writing model go in as formatted text where the app keeps formatting.
    public var formatPaste: Bool?
    public var formatForApp: Bool {
        get { formatPaste ?? true }
        set { formatPaste = newValue }
    }
    /// Hints and reminders of the first days, and your typing speed.
    public var coaching: Coaching?
    public var coachingState: Coaching {
        get { coaching ?? Coaching() }
        set { coaching = newValue }
    }
    public init() {}
    /// The style for an app, or for the site it shows: its own if you chose one, Verbatim in a
    /// terminal, where a new line would run a command, its kind's, and otherwise the default.
    public func style(for bundleID: String, site: Site? = nil) -> WritingStyle { styleChoice(for: bundleID, site: site).style }
    /// The style, whether it is the place's own or its kind's rather than the default, and the
    /// key it is kept under when it is the place's own.
    public func styleChoice(for bundleID: String, site: Site? = nil) -> (style: WritingStyle, own: Bool, key: String?) {
        for key in [site?.styleKey, bundleID].compactMap({ $0 }) {
            // Custom with nothing written for it gives way to what comes next.
            if let own = appStyles[key], own != .custom || stylePrompt(forKey: key) != nil { return (own, true, key) }
        }
        if CodeBundles.terminals.contains(bundleID) { return (.verbatim, false, nil) }
        if let kind = categoryStyles[Places.category(bundleID: bundleID, site: site)], kind != .custom { return (kind, true, nil) }
        return (style == .custom ? .natural : style, false, nil)
    }
    /// What you wrote for the app or site whose style is Custom.
    public func stylePrompt(for bundleID: String, site: Site? = nil) -> String? {
        let choice = styleChoice(for: bundleID, site: site)
        guard choice.style == .custom, let key = choice.key else { return nil }
        return stylePrompt(forKey: key)
    }
    func stylePrompt(forKey key: String) -> String? {
        guard appStyles[key] == .custom, let text = stylePrompts[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(1000))
    }
}

public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var word: String
    public var heardAs: String
    public init(id: UUID = UUID(), word: String, heardAs: String = "") { self.id = id; self.word = word; self.heardAs = heardAs }
}
public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    /// The text is Markdown, pasted as formatted text.
    public var formatted: Bool?
    public var isFormatted: Bool { formatted == true }
    public init(id: UUID = UUID(), trigger: String, expansion: String, formatted: Bool? = nil) { self.id = id; self.trigger = trigger; self.expansion = expansion; self.formatted = formatted }
}
/// A word Verb noticed you retype after a dictation, waiting for your yes.
public struct VocabularySuggestion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var word: String
    /// What the engine wrote. Empty when only the spelling is suggested, because what it wrote
    /// is a common word that a correction would change everywhere.
    public var heardAs: String
    public var date: Date
    public init(id: UUID = UUID(), word: String, heardAs: String, date: Date = Date()) { self.id = id; self.word = word; self.heardAs = heardAs; self.date = date }
}
public struct Transform: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instruction: String
    /// The keys that apply it, if any.
    public var keys: KeyBinding?
    public init(id: UUID = UUID(), name: String, instruction: String, keys: KeyBinding? = nil) { self.id = id; self.name = name; self.instruction = instruction; self.keys = keys }
    /// The transforms Verb starts with, in English and in Italian, in the same order.
    static let standard: [(names: [String], instructions: [String])] = [
        (["Polish", "Rifinisci"], ["Improve grammar and readability. Keep all meaning and the original language.", "Migliora grammatica e leggibilità. Mantieni tutto il significato e la lingua originale."]),
        (["Make concise", "Rendi conciso"], ["Make the text more concise without losing facts or changing the language.", "Rendi il testo più conciso senza perdere fatti né cambiare lingua."]),
        (["Translate into Italian", "Traduci in italiano"], ["Translate the text into natural Italian. Preserve names, numbers and formatting.", "Traduci il testo in un italiano naturale. Mantieni nomi, numeri e formattazione."]),
        (["Translate into English", "Traduci in inglese"], ["Translate the text into natural English. Preserve names, numbers and formatting.", "Traduci il testo in un inglese naturale. Mantieni nomi, numeri e formattazione."]),
    ]
    public static func defaults(italian: Bool) -> [Transform] {
        standard.enumerated().map { index, entry in Transform(name: entry.names[italian ? 1 : 0], instruction: entry.instructions[italian ? 1 : 0], keys: .transformDigit(index)) }
    }
    public static let defaults = defaults(italian: false)
    /// Verb's own transforms missing from the list, in the interface's language. One is there
    /// under either language's name, or still as Verb made it.
    public static func missing(from transforms: [Transform], italian: Bool) -> [Transform] {
        let names = Set(transforms.map { $0.name.lowercased() })
        return defaults(italian: italian).enumerated().filter { index, _ in
            !transforms.contains { $0.standardIndex == index } && !standard[index].names.contains { names.contains($0.lowercased()) }
        }.map(\.element)
    }
    /// Which of Verb's own transforms this is, while it is still as Verb made it.
    var standardIndex: Int? {
        let names = ["Translate to English"] + Self.standard.flatMap(\.names)
        guard names.contains(name) else { return nil }
        return Self.standard.firstIndex { ($0.names.contains(name) || (name == "Translate to English" && $0.names[0] == "Translate into English")) && $0.instructions.contains(instruction) }
    }
}
public struct Library: Codable, Equatable, Sendable {
    public var vocabulary: [VocabularyEntry] = []
    public var snippets: [Snippet] = []
    public var transforms: [Transform] = Transform.defaults
    /// 1 when each transform carries its own keys. A library without it gives ⌃⌥1 to ⌃⌥9 to
    /// its first nine transforms, by position.
    public var keysVersion: Int? = 1
    /// Suggestions you turned down, so they are not offered again. Each is a digest of
    /// "heard→word": the words themselves, read from other apps, aren't kept.
    public var ignored: [String]?
    public init() {}
    /// A new library, its transforms in the interface's language.
    public init(italian: Bool) { transforms = Transform.defaults(italian: italian) }
    /// Transforms still as Verb made them follow the interface's language; edited ones stay as they are.
    public mutating func localizeStandardTransforms(italian: Bool) {
        for index in transforms.indices {
            guard let standard = transforms[index].standardIndex else { continue }
            let entry = Transform.standard[standard]
            transforms[index].name = entry.names[italian ? 1 : 0]; transforms[index].instruction = entry.instructions[italian ? 1 : 0]
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        snippets = try values.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        transforms = try values.decodeIfPresent([Transform].self, forKey: .transforms) ?? Transform.defaults
        keysVersion = try values.decodeIfPresent(Int.self, forKey: .keysVersion)
        ignored = try values.decodeIfPresent([String].self, forKey: .ignored)?.map { $0.contains("→") ? Library.ignoreKey($0) : $0 }
        if keysVersion == nil {
            for index in transforms.indices.prefix(9) where transforms[index].keys == nil { transforms[index].keys = .transformDigit(index) }
            keysVersion = 1
        }
    }
    /// The digest a turned-down suggestion is remembered by.
    public static func ignoreKey(heard: String, word: String) -> String { ignoreKey(heard.lowercased() + "→" + word) }
    static func ignoreKey(_ pair: String) -> String { SHA256.hash(data: Data(pair.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
    /// The first ⌃⌥ digit no transform uses, for a new one.
    public func freeTransformKeys(keys: KeyBindings) -> KeyBinding? {
        (0..<9).map(KeyBinding.transformDigit).first { KeyBindings.owner(of: $0, keys: keys, transforms: transforms) == nil }
    }
}
public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var rawText: String
    public var text: String
    public var appName: String
    public var bundleID: String
    public var language: String
    public var engine: String
    public var mode: CaptureMode
    public var status: SessionStatus
    public var audioName: String?
    public var error: String?
    public var processingSeconds: Double
    public var delivery: String
    /// Set when "Ehi Verb" started the dictation, so its recording opens with the phrase.
    public var startedByVoice: Bool?
    /// Set when the dictation went on without the keys, so it may end with "Ehi Verb stop".
    public var handsFree: Bool?
    /// Seconds of voice in the recording, pauses left out. Absent when it wasn't measured.
    public var voiced: Double?
    /// What Verb put right in it: hesitations and repeats, dictionary corrections, snippets.
    public var fixes: Int?
    public init(id: UUID = UUID(), createdAt: Date = Date(), duration: Double = 0, rawText: String = "", text: String = "", appName: String = "Verb", bundleID: String = "", language: String = "auto", engine: String = "", mode: CaptureMode = .dictation, status: SessionStatus = .recorded, audioName: String? = nil, error: String? = nil, processingSeconds: Double = 0, delivery: String = "", startedByVoice: Bool? = nil, handsFree: Bool? = nil, voiced: Double? = nil, fixes: Int? = nil) {
        self.id = id; self.createdAt = createdAt; self.duration = duration; self.rawText = rawText; self.text = text; self.appName = appName; self.bundleID = bundleID; self.language = language; self.engine = engine; self.mode = mode; self.status = status; self.audioName = audioName; self.error = error; self.processingSeconds = processingSeconds; self.delivery = delivery; self.startedByVoice = startedByVoice; self.handsFree = handsFree; self.voiced = voiced; self.fixes = fixes
    }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}
public struct VerbError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
