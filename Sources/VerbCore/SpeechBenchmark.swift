import Foundation

/// One recording of a speech benchmark set, as its manifest lists it.
public struct SpeechBenchmarkClip: Codable, Equatable, Sendable {
    /// "speech" is one read sentence, "long" several in a row to exercise chunking, and
    /// "nonspeech" silence or noise, where the right transcript is empty.
    public enum Kind: String, Codable, CaseIterable, Sendable { case speech, long, nonspeech }
    public let id: String
    public let source: String
    public let kind: Kind
    /// ISO 639-1, or "und" for non-speech.
    public let language: String
    /// Relative to the manifest's folder. Several files play in a row with a short pause between them.
    public let audio: [String]
    public let reference: String
    public let seconds: Double
    public init(id: String, source: String, kind: Kind, language: String, audio: [String], reference: String, seconds: Double) {
        self.id = id; self.source = source; self.kind = kind; self.language = language; self.audio = audio; self.reference = reference; self.seconds = seconds
    }
    /// One clip per line.
    public static func manifest(_ data: Data) throws -> [SpeechBenchmarkClip] {
        let decoder = JSONDecoder()
        return try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { try decoder.decode(SpeechBenchmarkClip.self, from: Data($0.utf8)) }
    }
}

/// One clip transcribed by one model.
public struct SpeechBenchmarkResult: Codable, Equatable, Sendable {
    /// "hint" tells the model the clip's language; "auto" lets it detect, as Verb's Automatic setting does.
    public enum Mode: String, Codable, CaseIterable, Sendable { case hint, auto }
    public let model: String
    public let mode: Mode
    public let clip: String
    public let kind: SpeechBenchmarkClip.Kind
    public let language: String
    public let seconds: Double
    /// Processing time with the model loaded and warm.
    public let elapsed: Double
    public let text: String
    public let words: EditCounts
    /// Case and punctuation count too.
    public let formatted: EditCounts
    public let error: String?
    public init(model: String, mode: Mode, clip: String, kind: SpeechBenchmarkClip.Kind, language: String, seconds: Double, elapsed: Double, text: String, words: EditCounts, formatted: EditCounts, error: String? = nil) {
        self.model = model; self.mode = mode; self.clip = clip; self.kind = kind; self.language = language; self.seconds = seconds
        self.elapsed = elapsed; self.text = text; self.words = words; self.formatted = formatted; self.error = error
    }
}

/// What a model is and what it cost on the Mac that ran it.
public struct SpeechBenchmarkRun: Codable, Equatable, Sendable {
    public let model: String
    public let repository: String
    public let revision: String
    public let architecture: SpeechArchitecture
    public let languages: [String]
    public let loadSeconds: Double
    /// The first decode after loading, which also prepares the GPU kernels.
    public let firstSeconds: Double
    public let peakBytes: Int64
    public let diskBytes: Int64
    public let machine: String
    public let date: Date
    public init(model: String, repository: String, revision: String, architecture: SpeechArchitecture, languages: [String], loadSeconds: Double, firstSeconds: Double, peakBytes: Int64, diskBytes: Int64, machine: String, date: Date) {
        self.model = model; self.repository = repository; self.revision = revision; self.architecture = architecture; self.languages = languages
        self.loadSeconds = loadSeconds; self.firstSeconds = firstSeconds; self.peakBytes = peakBytes; self.diskBytes = diskBytes; self.machine = machine; self.date = date
    }
}

/// A results file holds one of these per line, so runs on different days or Macs can be concatenated.
public struct SpeechBenchmarkLine: Codable, Sendable {
    public var run: SpeechBenchmarkRun?
    public var result: SpeechBenchmarkResult?
    public init(run: SpeechBenchmarkRun) { self.run = run }
    public init(result: SpeechBenchmarkResult) { self.result = result }
    public static func read(_ data: Data) throws -> (runs: [SpeechBenchmarkRun], results: [SpeechBenchmarkResult]) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let lines = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { try decoder.decode(SpeechBenchmarkLine.self, from: Data($0.utf8)) }
        return (lines.compactMap(\.run), lines.compactMap(\.result))
    }
}

public struct SpeechBenchmarkSummary: Equatable, Sendable {
    public let model: String
    public let mode: SpeechBenchmarkResult.Mode
    /// Corpus error rate per language over single sentences: all edits over all reference units.
    public let errorRate: [String: Double]
    public let formattedRate: [String: Double]
    public let longRate: Double?
    /// Words written per non-speech clip, where the right answer is none.
    public let nonspeechWords: Double?
    /// Seconds per sentence.
    public let latency50: Double?
    public let latency95: Double?
    /// Seconds of audio transcribed per second.
    public let speed: Double?
    public let failures: Int

    /// The weighted mean over the given languages, or nil when one of them was not run.
    public func weighted(_ weights: [String: Double], over languages: Set<String>) -> Double? {
        var total = 0.0, weight = 0.0
        for language in languages {
            guard let rate = errorRate[language] else { return nil }
            let share = weights[language] ?? 1; total += rate * share; weight += share
        }
        return weight > 0 ? total / weight : nil
    }
}

public enum SpeechBenchmarkReport {
    public struct Limits: Sendable {
        /// A model must cover these to be picked: Verb's own languages.
        public var required: Set<String> = ["en", "it"]
        public var weights: [String: Double] = ["en": 2, "it": 2]
        /// Seconds per sentence at the 95th percentile, for the default.
        public var latency: Double = 1.0
        public var memory: Int64 = 3_000_000_000
        /// How much worse than the most accurate model the fastest may be, as a share.
        public var tolerance: Double = 0.5
        public init() {}
    }
    public struct Choice: Equatable, Sendable {
        public let model: String
        public let mode: SpeechBenchmarkResult.Mode
        public let errorRate: Double
        public let latency50: Double?
    }
    public struct Picks: Equatable, Sendable {
        /// The most accurate model that detects the language and fits the latency and memory limits.
        public let standard: Choice?
        public let best: Choice?
        /// The quickest model within the tolerance of the most accurate.
        public let fastest: Choice?
        /// The languages every eligible model covers, which the error rates are averaged over.
        public let languages: [String]
    }

    /// A clip run twice by the same model and mode counts once, with its latest result.
    public static func summaries(_ results: [SpeechBenchmarkResult]) -> [SpeechBenchmarkSummary] {
        var latest: [String: SpeechBenchmarkResult] = [:]
        for result in results { latest["\(result.model)\u{0}\(result.mode.rawValue)\u{0}\(result.clip)"] = result }
        return Dictionary(grouping: latest.values) { "\($0.model)\u{0}\($0.mode.rawValue)" }.values.map { group in
            let speech = group.filter { $0.kind == .speech }, nonspeech = group.filter { $0.kind == .nonspeech }
            var rates: [String: Double] = [:], formatted: [String: Double] = [:]
            for (language, items) in Dictionary(grouping: speech, by: \.language) {
                rates[language] = items.map(\.words).reduce(EditCounts(), +).rate
                formatted[language] = items.map(\.formatted).reduce(EditCounts(), +).rate
            }
            let audio = speech.reduce(0) { $0 + $1.seconds }, spent = speech.reduce(0) { $0 + $1.elapsed }
            return SpeechBenchmarkSummary(
                model: group[0].model, mode: group[0].mode, errorRate: rates, formattedRate: formatted,
                longRate: group.filter { $0.kind == .long }.map(\.words).reduce(EditCounts(), +).rate,
                nonspeechWords: nonspeech.isEmpty ? nil : Double(nonspeech.reduce(0) { $0 + $1.words.insertions }) / Double(nonspeech.count),
                latency50: SpeechScoring.percentile(speech.map(\.elapsed), 0.5), latency95: SpeechScoring.percentile(speech.map(\.elapsed), 0.95),
                speed: spent > 0 ? audio / spent : nil, failures: group.filter { $0.error != nil }.count)
        }.sorted { ($0.model, $0.mode.rawValue) < ($1.model, $1.mode.rawValue) }
    }

    public static func picks(_ summaries: [SpeechBenchmarkSummary], runs: [SpeechBenchmarkRun], limits: Limits = Limits()) -> Picks {
        let eligible = summaries.filter { summary in limits.required.allSatisfy { summary.errorRate[$0] != nil } }
        guard let first = eligible.first else { return Picks(standard: nil, best: nil, fastest: nil, languages: []) }
        let common = eligible.reduce(Set(first.errorRate.keys)) { $0.intersection($1.errorRate.keys) }
        let ranked: [(SpeechBenchmarkSummary, Choice)] = eligible.compactMap { summary in
            summary.weighted(limits.weights, over: common).map { (summary, Choice(model: summary.model, mode: summary.mode, errorRate: $0, latency50: summary.latency50)) }
        }
        let best = ranked.min { $0.1.errorRate < $1.1.errorRate }?.1
        let fastest = best.flatMap { best in
            ranked.filter { $0.1.errorRate <= best.errorRate * (1 + limits.tolerance) }.min { ($0.0.latency50 ?? .infinity) < ($1.0.latency50 ?? .infinity) }?.1
        }
        let peak = Dictionary(runs.map { ($0.model, $0.peakBytes) }, uniquingKeysWith: max)
        let standard = ranked.filter { entry in
            entry.0.mode == .auto && (entry.0.latency95 ?? .infinity) <= limits.latency && (peak[entry.0.model] ?? 0) <= limits.memory
        }.min { ($0.1.errorRate, $0.0.latency50 ?? .infinity) < ($1.1.errorRate, $1.0.latency50 ?? .infinity) }?.1
        return Picks(standard: standard, best: best, fastest: fastest, languages: common.sorted())
    }

    public static func markdown(_ summaries: [SpeechBenchmarkSummary], runs: [SpeechBenchmarkRun], limits: Limits = Limits()) -> String {
        let picks = picks(summaries, runs: runs, limits: limits)
        let run = Dictionary(runs.map { ($0.model, $0) }, uniquingKeysWith: { $1 })
        let percent = { (value: Double?) in value.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
        let seconds = { (value: Double?) in value.map { String(format: "%.2f s", $0) } ?? "–" }
        let gigabytes = { (value: Int64?) in value.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "–" }
        func pick(_ title: String, _ choice: Choice?) -> String {
            guard let choice else { return "- **\(title):** none qualifies" }
            return "- **\(title):** \(choice.model) (\(choice.mode.rawValue)) · \(percent(choice.errorRate)) · \(seconds(choice.latency50)) per sentence"
        }
        let weights = limits.weights.sorted { $0.key < $1.key }.map { "\($0.key) ×\(String(format: "%g", $0.value))" }.joined(separator: ", ")
        var lines = ["# Speech benchmark", ""]
        if let machine = runs.first?.machine { lines += ["Run on \(machine).", ""] }
        lines += ["Error rates are averaged over \(picks.languages.isEmpty ? "no common languages" : picks.languages.joined(separator: ", ")), the languages every model covering \(limits.required.sorted().joined(separator: " and ")) supports, weighted \(weights.isEmpty ? "equally" : weights + ", others ×1").", ""]
        lines += ["## Picks", "",
                  pick("Default", picks.standard) + " · detects the language, p95 under \(seconds(limits.latency)), peak memory under \(gigabytes(limits.memory))",
                  pick("Most accurate", picks.best),
                  pick("Fastest", picks.fastest) + " · within \(Int(limits.tolerance * 100))% of the most accurate", ""]
        lines += ["## Models", "", "| Model | Mode | Error | Formatted | Long | Non-speech words | p50 | p95 | Speed | Load | Peak memory | Disk | Failures |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        let common = Set(picks.languages)
        for summary in summaries {
            let formatted = SpeechBenchmarkSummary(model: summary.model, mode: summary.mode, errorRate: summary.formattedRate, formattedRate: [:], longRate: nil, nonspeechWords: nil, latency50: nil, latency95: nil, speed: nil, failures: 0)
            let info = run[summary.model]
            lines.append("| \(summary.model) | \(summary.mode.rawValue) | \(percent(summary.weighted(limits.weights, over: common))) | \(percent(formatted.weighted(limits.weights, over: common))) | \(percent(summary.longRate)) | \(summary.nonspeechWords.map { String(format: "%.1f", $0) } ?? "–") | \(seconds(summary.latency50)) | \(seconds(summary.latency95)) | \(summary.speed.map { String(format: "%.0f×", $0) } ?? "–") | \(seconds(info?.loadSeconds)) | \(gigabytes(info?.peakBytes)) | \(gigabytes(info?.diskBytes)) | \(summary.failures) |")
        }
        let languages = Set(summaries.flatMap(\.errorRate.keys)).sorted { (limits.required.contains($0) ? 0 : 1, $0) < (limits.required.contains($1) ? 0 : 1, $1) }
        for (title, rates) in [("Error rate by language", \SpeechBenchmarkSummary.errorRate), ("Formatted error rate by language", \SpeechBenchmarkSummary.formattedRate)] {
            lines += ["", "## \(title)", "", "| Model | Mode | " + languages.joined(separator: " | ") + " |", "|---|---|" + String(repeating: "---|", count: languages.count)]
            for summary in summaries { lines.append("| \(summary.model) | \(summary.mode.rawValue) | " + languages.map { percent(summary[keyPath: rates][$0]) }.joined(separator: " | ") + " |") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
