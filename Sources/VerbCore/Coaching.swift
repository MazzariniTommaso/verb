import Foundation

/// What Verb remembers to help in the first days, and to say a thing once rather than every time:
/// when it first ran, the hints it gave, how fast you type. Nothing here comes from other apps.
public struct Coaching: Codable, Equatable, Sendable {
    /// The first launch with this setting, the start of the first days.
    public var firstRun: Date?
    /// When a hint about the dictation keys was shown.
    public var keyHints: [Date] = []
    /// The microphones said to be slow to open, and when.
    public var slowMicrophones: [String: Date] = [:]
    /// When a reminder to dictate was shown.
    public var nudges: [Date] = []
    /// Your typing speed, measured in the welcome, in words per minute.
    public var typingSpeed: Double?
    /// The first dictation in an app, with Verb guiding it, is done.
    public var firstMessage: Bool?
    public init() {}
    // Tolerates missing keys so later additions never discard what is kept.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        firstRun = try values.decodeIfPresent(Date.self, forKey: .firstRun)
        keyHints = try values.decodeIfPresent([Date].self, forKey: .keyHints) ?? []
        slowMicrophones = try values.decodeIfPresent([String: Date].self, forKey: .slowMicrophones) ?? [:]
        nudges = try values.decodeIfPresent([Date].self, forKey: .nudges) ?? []
        typingSpeed = try values.decodeIfPresent(Double.self, forKey: .typingSpeed)
        firstMessage = try values.decodeIfPresent(Bool.self, forKey: .firstMessage)
    }

    /// The first days, when Verb still offers hints and reminders.
    public func inFirstDays(_ now: Date, days: Double) -> Bool {
        guard let firstRun else { return false }
        return now.timeIntervalSince(firstRun) < days * 86400
    }
    /// At most one a day, and only a few in all.
    static func allowed(_ shown: [Date], now: Date, most: Int, calendar: Calendar) -> Bool {
        shown.count < most && !shown.contains { calendar.isDate($0, inSameDayAs: now) }
    }

    /// Modifiers held alone for a while and let go, that aren't the dictation keys: someone
    /// trying to dictate with the wrong keys. The second within a quarter of a minute brings the
    /// hint, once a day, five times at most, in the first two weeks.
    public mutating func lonePress(_ modifiers: KeyModifiers, held: Double, dictation: KeyModifiers?, recent: inout [Date], now: Date, calendar: Calendar = .current) -> Bool {
        guard let dictation, modifiers != dictation, held >= 0.7, held <= 6,
              [KeyModifiers.control, .option, .function, [.control, .option], [.control, .function], [.option, .function]].contains(modifiers) else { return false }
        recent = recent.filter { now.timeIntervalSince($0) < 15 } + [now]
        guard recent.count >= 2, inFirstDays(now, days: 14), Self.allowed(keyHints, now: now, most: 5, calendar: calendar) else { return false }
        keyHints.append(now); recent = []
        return true
    }

    /// A microphone took this long to open. Slow twice in its last three openings, it is said once
    /// a week: the first words can be lost while it opens.
    public mutating func microphoneOpened(_ id: String, seconds: Double, history: inout [String: [Double]], now: Date) -> Bool {
        var times = (history[id] ?? []) + [seconds]
        if times.count > 3 { times.removeFirst(times.count - 3) }
        history[id] = times
        guard seconds >= Self.slowOpening, times.filter({ $0 >= Self.slowOpening }).count >= 2 else { return false }
        if let last = slowMicrophones[id], now.timeIntervalSince(last) < 7 * 86400 { return false }
        slowMicrophones[id] = now
        return true
    }
    /// Past this, in seconds, the first words risk being lost.
    public static let slowOpening = 0.7

    /// A reminder to dictate, while you type a long text by hand: in the first three days, once
    /// a day, three times in all, never in the first three hours nor soon after a dictation.
    public mutating func nudge(typed: Int, lastDictation: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard typed >= 120, let firstRun, now.timeIntervalSince(firstRun) >= 3 * 3600, inFirstDays(now, days: 3),
              lastDictation.map({ now.timeIntervalSince($0) > 2 * 3600 }) ?? true,
              Self.allowed(nudges, now: now, most: 3, calendar: calendar) else { return false }
        nudges.append(now)
        return true
    }
}

/// How fast you type, and what speaking instead saves.
public enum Speed {
    /// Words per minute for a text typed in `seconds`, counting five characters as a word, as
    /// typing tests do; nil for a test too short to say.
    public static func typing(_ text: String, seconds: Double) -> Double? {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characters >= 20, seconds >= 3 else { return nil }
        return Double(characters) / 5 / (seconds / 60)
    }
    /// Words per minute for words spoken in `seconds`.
    public static func speaking(words: Int, seconds: Double) -> Double? {
        guard words >= 4, seconds >= 2 else { return nil }
        return Double(words) / (seconds / 60)
    }
    /// Hours a week that speaking saves over typing, for `hours` a day at the keyboard, five
    /// days a week, of which half is writing.
    public static func hoursSaved(typing: Double, speaking: Double, hoursPerDay: Double = 6) -> Double {
        guard typing > 0, speaking > typing else { return 0 }
        let writing = hoursPerDay * 5 * 0.5
        return writing * (1 - typing / speaking)
    }
}

/// A week of dictation beside the one before: what Home shows on Mondays and all week.
public struct WeekRecap: Equatable, Sendable {
    public let words: Int
    public let previousWords: Int
    public let activeDays: Int
    /// Minutes saved against typing, at `typing` words per minute.
    public let minutesSaved: Int
    public let topApp: String?
    /// The change against the week before, from -1 up; nil without a week before to compare with.
    public var change: Double? { previousWords > 0 ? Double(words - previousWords) / Double(previousWords) : nil }
}

extension DictationStats {
    /// The last seven days up to today, against the seven before. The app is the one with the
    /// most words overall: the totals don't keep apps by day.
    public func recap(today: Date = Date(), typing: Double = DictationStats.typingWordsPerMinute, calendar: Calendar = .current) -> WeekRecap {
        func words(daysBack range: Range<Int>) -> (words: Int, days: Int) {
            var total = 0, active = 0
            for back in range {
                guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
                let count = days[Self.day(day, calendar: calendar)] ?? 0
                total += count; if count > 0 { active += 1 }
            }
            return (total, active)
        }
        let this = words(daysBack: 0..<7), before = words(daysBack: 7..<14)
        // Speaking takes time too: what is saved is typing time less speaking time.
        let speaking = wordsPerMinute ?? 120
        let saved = speaking > typing ? Double(this.words) / typing - Double(this.words) / speaking : 0
        return WeekRecap(words: this.words, previousWords: before.words, activeDays: this.days, minutesSaved: max(0, Int(saved.rounded())), topApp: topApps(1).first?.name)
    }
}
