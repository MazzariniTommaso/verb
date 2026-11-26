import Foundation
import VerbCore
import VerbEngine

/// Runs speech models over a benchmark set on this Mac, one JSON line per clip, and turns the lines
/// into a report. See "Speech benchmark" in the README.
enum SpeechBench {
    /// One entry of a models file such as Benchmarks/speech-models.json.
    struct Candidate: Decodable {
        let name: String
        /// "owner/name", optionally "@revision".
        let repository: String
        /// ISO 639-1 codes the model claims. Clips in other languages are skipped.
        let languages: [String]
        /// An installed copy to use instead of downloading one.
        let folder: String?
    }

    static func run(_ arguments: [String]) async throws {
        let (positional, options) = parse(arguments)
        guard positional.count == 3 else { throw VerbError("Usage: verb-check speech-bench MANIFEST MODELS RESULTS [--root DIR] [--only NAMES] [--languages CODES] [--limit N] [--kinds KINDS] [--modes MODES] [--warmup N]") }
        let manifest = URL(fileURLWithPath: expand(positional[0])), base = manifest.deletingLastPathComponent()
        let only = list(options["only"]), languages = list(options["languages"])
        let kinds = list(options["kinds"]).map { Set($0.compactMap(SpeechBenchmarkClip.Kind.init(rawValue:))) } ?? Set(SpeechBenchmarkClip.Kind.allCases)
        let modes = list(options["modes"]).map { Set($0.compactMap(SpeechBenchmarkResult.Mode.init(rawValue:))) } ?? Set(SpeechBenchmarkResult.Mode.allCases)
        let root = URL(fileURLWithPath: expand(options["root"] ?? "~/Library/Caches/Verb/SpeechModels"))
        let warmup = max(1, options["warmup"].flatMap(Int.init) ?? 2)

        var clips = try SpeechBenchmarkClip.manifest(Data(contentsOf: manifest)).filter { clip in
            kinds.contains(clip.kind) && (clip.kind == .nonspeech || languages.map { $0.contains(clip.language) } ?? true)
        }
        if let limit = options["limit"].flatMap(Int.init) {
            var counts: [String: Int] = [:]
            clips = clips.filter { clip in counts["\(clip.kind.rawValue) \(clip.language)", default: 0] += 1; return counts["\(clip.kind.rawValue) \(clip.language)"]! <= limit }
        }
        let candidates = try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: URL(fileURLWithPath: expand(positional[1])))).filter { only?.contains($0.name) ?? true }
        guard !candidates.isEmpty, !clips.isEmpty else { throw VerbError("Nothing to run: check --only, --languages and --kinds.") }

        let output = URL(fileURLWithPath: expand(positional[2]))
        if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        try handle.seekToEnd()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        func write(_ line: SpeechBenchmarkLine) throws { var data = try encoder.encode(line); data.append(0x0A); try handle.write(contentsOf: data) }
        let machine = machineDescription()

        for candidate in candidates {
            let folder = candidate.folder.map { URL(fileURLWithPath: expand($0)) } ?? root.appendingPathComponent(candidate.name)
            let record: SpeechModelInstaller.Record
            if let installed = SpeechModelInstaller.record(in: folder) { record = installed }
            else if candidate.folder != nil { record = .init(repository: candidate.repository, revision: "local", architecture: try SpeechModels.architecture(of: folder), files: [], companion: nil) }
            else {
                print("Installing \(candidate.name) from \(candidate.repository)…")
                let steps = ProgressSteps()
                record = try await SpeechModelInstaller.install(candidate.repository, into: folder) { value, _ in
                    if let percent = steps.next(value) { print("  \(percent)%") }
                }
            }
            SpeechMemory.resetPeak()
            let loadStart = Date()
            let runner = try await SpeechModels.load(folder)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let declared = Set(candidate.languages)
            let selected = clips.filter { $0.kind == .nonspeech || declared.contains($0.language) }
            let runModes: [SpeechBenchmarkResult.Mode]
            switch runner.architecture.languageUse {
            case .hinted: runModes = [.hint, .auto]
            case .required: runModes = [.hint]
            case .detects, .translates: runModes = [.auto]
            }
            // The first decodes compile the GPU kernels: timed, not scored.
            var firstSeconds = 0.0
            for (number, clip) in selected.filter({ $0.kind == .speech }).prefix(warmup).enumerated() {
                let samples = try audio(clip, base: base), start = Date()
                _ = try await runner.transcribe(samples, language: clip.language)
                if number == 0 { firstSeconds = Date().timeIntervalSince(start) }
            }
            print("\(candidate.name): \(runner.architecture.rawValue), loaded in \(String(format: "%.1f", loadSeconds)) s, \(selected.count) clips")
            for mode in runModes where modes.contains(mode) {
                var total = EditCounts(), done = 0
                for clip in selected {
                    let samples = try audio(clip, base: base)
                    let language = mode == .hint ? (clip.kind == .nonspeech ? "en" : clip.language) : nil
                    var text = "", failure: String?
                    let start = Date()
                    do { text = try await runner.transcribe(samples, language: language).text } catch { failure = error.localizedDescription }
                    let elapsed = Date().timeIntervalSince(start)
                    let words = SpeechScoring.score(reference: clip.reference, hypothesis: text, language: clip.language)
                    let formatted = SpeechScoring.scoreFormatted(reference: clip.reference, hypothesis: text, language: clip.language)
                    try write(SpeechBenchmarkLine(result: SpeechBenchmarkResult(model: candidate.name, mode: mode, clip: clip.id, kind: clip.kind, language: clip.language, seconds: clip.seconds, elapsed: elapsed, text: text, words: words, formatted: formatted, error: failure)))
                    if clip.kind == .speech { total = total + words }
                    done += 1
                    if done % 50 == 0 || done == selected.count {
                        print("  \(mode.rawValue) \(done)/\(selected.count) · error so far \(total.rate.map { String(format: "%.1f%%", $0 * 100) } ?? "–")")
                    }
                }
            }
            let disk = record.files.isEmpty ? folderSize(folder) : record.files.reduce(0) { $0 + $1.size }
            try write(SpeechBenchmarkLine(run: SpeechBenchmarkRun(model: candidate.name, repository: record.repository, revision: record.revision, architecture: runner.architecture, languages: candidate.languages, loadSeconds: loadSeconds, firstSeconds: firstSeconds, peakBytes: SpeechMemory.peak, diskBytes: disk, machine: machine, date: Date())))
        }
        print("Results in \(output.path). Summarize with: verb-check speech-bench-report \(output.path)")
    }

    static func report(_ arguments: [String]) throws {
        let (files, options) = parse(arguments)
        guard !files.isEmpty else { throw VerbError("Usage: verb-check speech-bench-report RESULTS... [--weights it=2,en=2] [--require en,it] [--latency SECONDS] [--memory GB] [--tolerance SHARE]") }
        var runs: [SpeechBenchmarkRun] = [], results: [SpeechBenchmarkResult] = []
        for file in files {
            let read = try SpeechBenchmarkLine.read(Data(contentsOf: URL(fileURLWithPath: expand(file))))
            runs += read.runs; results += read.results
        }
        var limits = SpeechBenchmarkReport.Limits()
        if let weights = list(options["weights"]) {
            limits.weights = Dictionary(weights.compactMap { pair -> (String, Double)? in
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { return nil }
                return (String(parts[0]), value)
            }, uniquingKeysWith: { $1 })
        }
        if let required = list(options["require"]) { limits.required = required }
        if let latency = options["latency"].flatMap(Double.init) { limits.latency = latency }
        if let memory = options["memory"].flatMap(Double.init) { limits.memory = Int64(memory * 1e9) }
        if let tolerance = options["tolerance"].flatMap(Double.init) { limits.tolerance = tolerance }
        print(SpeechBenchmarkReport.markdown(SpeechBenchmarkReport.summaries(results), runs: runs, limits: limits), terminator: "")
    }

    /// Transcribes one recording with an installed model, for a first look at a new one.
    static func transcribe(folder: String, audio path: String, language: String?) async throws {
        let runner = try await SpeechModels.load(URL(fileURLWithPath: expand(folder)))
        let samples = try SpeechPCM.read(URL(fileURLWithPath: expand(path))), start = Date()
        let result = try await runner.transcribe(samples, language: language)
        let data = try JSONSerialization.data(withJSONObject: ["architecture": runner.architecture.rawValue, "text": result.text, "language": result.language ?? "", "seconds": Date().timeIntervalSince(start)], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func install(_ repository: String, folder: String) async throws {
        let steps = ProgressSteps()
        let record = try await SpeechModelInstaller.install(repository, into: URL(fileURLWithPath: expand(folder))) { value, state in
            if let percent = steps.next(value) { print("\(percent)% \(state)") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(record), as: UTF8.self))
    }

    /// The clip's files in a row, 0.4 seconds apart, at 16 kHz.
    static func audio(_ clip: SpeechBenchmarkClip, base: URL) throws -> [Float] {
        var samples: [Float] = []
        for (index, file) in clip.audio.enumerated() {
            if index > 0 { samples += [Float](repeating: 0, count: 6400) }
            samples += try SpeechPCM.read(base.appendingPathComponent(file))
        }
        return samples
    }

    static func parse(_ arguments: [String]) -> ([String], [String: String]) {
        var positional: [String] = [], options: [String: String] = [:], index = 0
        while index < arguments.count {
            if arguments[index].hasPrefix("--"), index + 1 < arguments.count { options[String(arguments[index].dropFirst(2))] = arguments[index + 1]; index += 2 }
            else { positional.append(arguments[index]); index += 1 }
        }
        return (positional, options)
    }
    static func list(_ value: String?) -> Set<String>? {
        value.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
    }
    static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    static func folderSize(_ folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func machineDescription() -> String {
        func text(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(cString: buffer)
        }
        var memory: UInt64 = 0, size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(text("machdep.cpu.brand_string")), \(memory / 1_073_741_824) GB, macOS \(os.majorVersion).\(os.minorVersion)"
    }
}

/// Turns download progress into one line per 5%, from any thread.
private final class ProgressSteps: @unchecked Sendable {
    private let lock = NSLock(); private var shown = -1
    func next(_ value: Double) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let step = Int(value * 20)
        guard step != shown else { return nil }
        shown = step; return step * 5
    }
}
