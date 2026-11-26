import XCTest
@testable import VerbCore

/// Scoring transcripts the way the public leaderboards do, and reading speech models from their files.
final class SpeechScoringTests: XCTestCase {
    func testCaseAndPunctuationDoNotCount() {
        let counts = SpeechScoring.score(reference: "L'incidente è avvenuto in alta montagna.", hypothesis: "l’incidente è avvenuto in alta montagna", language: "it")
        XCTAssertEqual(counts.errors, 0)
        XCTAssertEqual(counts.reference, 7, "The apostrophe splits l'incidente in two, on both sides alike")
    }
    func testEachKindOfEditIsCounted() {
        let counts = SpeechScoring.edits(reference: ["send", "it", "to", "jamie", "today"], hypothesis: ["send", "it", "to", "jenny", "today", "please"])
        XCTAssertEqual(counts, EditCounts(substitutions: 1, deletions: 0, insertions: 1, reference: 5))
        XCTAssertEqual(counts.rate!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(SpeechScoring.edits(reference: ["a", "b", "c"], hypothesis: ["a", "c"]), EditCounts(deletions: 1, reference: 3))
        XCTAssertEqual(SpeechScoring.edits(reference: [], hypothesis: ["noise"]), EditCounts(insertions: 1), "Words on silence are insertions with no rate")
        XCTAssertNil(SpeechScoring.edits(reference: [], hypothesis: ["noise"]).rate)
    }
    func testChineseAndJapaneseAreScoredByCharacter() {
        XCTAssertEqual(SpeechScoring.units("我们明天见。", language: "zh"), ["我", "们", "明", "天", "见"])
        XCTAssertEqual(SpeechScoring.score(reference: "今日は晴れです", hypothesis: "今日は雨です", language: "ja-JP"), EditCounts(substitutions: 1, deletions: 1, reference: 7))
    }
    func testCombiningMarksStayInsideWords() {
        XCTAssertEqual(SpeechScoring.units("नमस्ते दुनिया", language: "hi").count, 2, "Devanagari vowel signs are marks, not punctuation")
    }
    func testAnnotationsAreDroppedButParenthesesWereSpoken() {
        XCTAssertEqual(SpeechScoring.units("Ciao [risata] a tutti <unk>", language: "it"), ["ciao", "a", "tutti"])
        XCTAssertEqual(SpeechScoring.units("Un visto separato (a partire dal 2009)", language: "it"), ["1", "visto", "separato", "a", "partire", "dal", "2009"])
    }
    func testNumbersScoreTheSameAsWordsOrDigits() {
        XCTAssertEqual(SpeechScoring.score(reference: "Ci vediamo alle 15, il budget è 2.500 euro.", hypothesis: "ci vediamo alle quindici il budget è duemilacinquecento euro", language: "it").errors, 0)
        XCTAssertEqual(SpeechScoring.score(reference: "vor ungefähr 10.000 Jahren", hypothesis: "vor ungefähr zehntausend Jahren", language: "de").errors, 0)
        XCTAssertEqual(SpeechScoring.score(reference: "It was built in 1987.", hypothesis: "it was built in nineteen eighty-seven", language: "en").errors, 0)
        XCTAssertEqual(SpeechScoring.score(reference: "Ci vediamo alle 15.", hypothesis: "Ci vediamo alle 16.", language: "it").errors, 1, "A wrong number is still an error")
    }
    func testFormattedScoreSeesCaseAndPunctuation() {
        let plain = SpeechScoring.scoreFormatted(reference: "Ci vediamo mercoledì.", hypothesis: "ci vediamo mercoledì", language: "it")
        XCTAssertEqual(plain, EditCounts(substitutions: 1, deletions: 1, reference: 4), "A lowercase start and a missing full stop cost one edit each")
        XCTAssertEqual(SpeechScoring.scoreFormatted(reference: "It’s “fine”.", hypothesis: "It's \"fine\".", language: "en").errors, 0, "Curly and straight quotes are the same mark")
    }
    func testPercentilesInterpolate() {
        XCTAssertEqual(SpeechScoring.percentile([4, 1, 3, 2], 0.5)!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(SpeechScoring.percentile([1, 2, 3, 4, 5], 0.95)!, 4.8, accuracy: 1e-9)
        XCTAssertNil(SpeechScoring.percentile([], 0.5))
    }
}

final class SpeechArchitectureTests: XCTestCase {
    private func detect(_ json: String) -> SpeechArchitecture? { SpeechArchitecture.detect(config: Data(json.utf8)) }

    func testFamiliesAreReadFromConfig() {
        XCTAssertEqual(detect(#"{"model_type": "cohere_asr"}"#), .cohere)
        XCTAssertEqual(detect(#"{"model_type": "qwen3_asr", "architectures": ["Qwen3ASRForConditionalGeneration"]}"#), .qwen3ASR)
        XCTAssertEqual(detect(#"{"model_type": "voxtral_realtime"}"#), .voxtralRealtime)
        XCTAssertEqual(detect(#"{"model_type": "nemotron_asr", "target": "nemo.collections.asr.models.rnnt_bpe_models_prompt.EncDecRNNTBPEModelWithPrompt"}"#), .nemotron)
        XCTAssertNil(detect(#"{"model_type": "llama"}"#), "A language model is not a speech model")
        XCTAssertNil(detect("not json"))
    }
    func testNeMoConversionsAreReadFromTheirClass() {
        XCTAssertEqual(detect(#"{"target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"}"#), .parakeet)
        XCTAssertEqual(detect(#"{"target": "nemo.collections.asr.models.ctc_bpe_models.EncDecCTCModelBPE"}"#), .parakeet)
        XCTAssertEqual(detect(#"{"target": "nemo.collections.asr.models.aed_multitask_models.EncDecMultiTaskModel"}"#), .canary)
        XCTAssertNil(detect(#"{"target": "nemo.collections.tts.models.FastPitchModel"}"#))
    }
    func testLanguagesReachEachFamilyInItsOwnForm() {
        XCTAssertEqual(SpeechArchitecture.qwen3ASR.hint(for: "it"), "Italian")
        XCTAssertEqual(SpeechArchitecture.qwen3ASR.hint(for: "nl"), "Dutch")
        XCTAssertEqual(SpeechArchitecture.nemotron.hint(for: "zh"), "zh-CN")
        XCTAssertEqual(SpeechArchitecture.nemotron.hint(for: "it"), "it")
        XCTAssertEqual(SpeechArchitecture.cohere.hint(for: "pt-BR"), "pt")
        XCTAssertNil(SpeechArchitecture.parakeet.hint(for: "it"), "Parakeet detects the language and takes no hint")
        XCTAssertNil(SpeechArchitecture.graniteSpeech.hint(for: "it"), "For Granite a language means translating into it")
        XCTAssertNil(SpeechArchitecture.whisper.hint(for: nil))
        XCTAssertNil(SpeechArchitecture.whisper.hint(for: "und"))
    }
    func testOnlyDataFilesAreFetched() throws {
        let tree = #"""
        [{"type":"file","oid":"a1","size":1519,"path":".gitattributes"},
         {"type":"file","oid":"b2","size":244093,"path":"config.json"},
         {"type":"file","oid":"c3","size":134,"path":"model.safetensors","lfs":{"oid":"ee62d5","size":1254184462,"pointerSize":134}},
         {"type":"file","oid":"d4","size":360916,"path":"tokenizer.model","lfs":{"oid":"eacec2","size":360916,"pointerSize":132}},
         {"type":"file","oid":"e5","size":46772,"path":"vocab.txt"},
         {"type":"file","oid":"f6","size":4000,"path":"modeling_glmasr.py"},
         {"type":"file","oid":"g7","size":900,"path":"README.md"},
         {"type":"file","oid":"h8","size":2000,"path":"pytorch_model.bin"},
         {"type":"file","oid":"i9","size":1600000,"path":"multilingual_sample.wav"},
         {"type":"file","oid":"j0","size":30,"path":".eval_results/open_asr_leaderboard.yaml"},
         {"type":"directory","oid":"k1","size":0,"path":"onnx"}]
        """#
        let files = try SpeechModelFiles.parseTree(Data(tree.utf8))
        XCTAssertEqual(SpeechModelFiles.needed(files).map(\.path), ["config.json", "model.safetensors", "tokenizer.model", "vocab.txt"])
        let weights = try XCTUnwrap(files.first { $0.path == "model.safetensors" })
        XCTAssertEqual(weights.size, 1254184462, "An LFS file's size is the content's, not the pointer's")
        XCTAssertEqual(weights.sha256, "ee62d5")
        XCTAssertNil(files.first { $0.path == "config.json" }?.sha256)
    }
    func testRepositoryNamesCannotLeaveHuggingFace() {
        XCTAssertTrue(SpeechModelFiles.isRepository("mlx-community/parakeet-tdt-0.6b-v3"))
        XCTAssertFalse(SpeechModelFiles.isRepository("../../etc/passwd"))
        XCTAssertFalse(SpeechModelFiles.isRepository("owner/name/extra"))
        XCTAssertFalse(SpeechModelFiles.isRepository("https://evil.example/x"))
        XCTAssertFalse(SpeechModelFiles.isRepository("owner/.."))
    }
}

final class SpeechBenchmarkReportTests: XCTestCase {
    private func result(_ model: String, _ mode: SpeechBenchmarkResult.Mode, _ language: String, errors: Int, of reference: Int = 10, elapsed: Double, kind: SpeechBenchmarkClip.Kind = .speech) -> SpeechBenchmarkResult {
        SpeechBenchmarkResult(model: model, mode: mode, clip: "\(model)-\(language)-\(UUID().uuidString)", kind: kind, language: language, seconds: 10, elapsed: elapsed,
                              text: "", words: EditCounts(substitutions: errors, reference: kind == .nonspeech ? 0 : reference), formatted: EditCounts(substitutions: errors + 1, reference: reference))
    }
    private func run(_ model: String, peak: Int64) -> SpeechBenchmarkRun {
        SpeechBenchmarkRun(model: model, repository: "owner/\(model)", revision: "abc", architecture: .parakeet, languages: ["en", "it"], loadSeconds: 1, firstSeconds: 1, peakBytes: peak, diskBytes: peak, machine: "Test Mac", date: Date(timeIntervalSince1970: 0))
    }

    func testErrorRatesAreCorpusLevelPerLanguage() {
        let summaries = SpeechBenchmarkReport.summaries([result("fast", .auto, "it", errors: 1, elapsed: 0.1), result("fast", .auto, "it", errors: 3, of: 30, elapsed: 0.3)])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].errorRate["it"]!, 0.1, accuracy: 1e-9, "4 errors over 40 words, not the mean of 10% and 10%")
        XCTAssertEqual(summaries[0].speed!, 50, accuracy: 1e-9)
    }
    func testPicksSeparateDefaultBestAndFastest() {
        var results: [SpeechBenchmarkResult] = []
        for language in ["en", "it", "es"] {
            // Accurate but needs the language and is slow.
            results.append(result("accurate", .hint, language, errors: 2, elapsed: 0.9))
            // Detects the language, a little less accurate, quick.
            results.append(result("balanced", .auto, language, errors: 3, elapsed: 0.2))
            results.append(result("balanced", .hint, language, errors: 3, elapsed: 0.2))
            // Fastest of all, but too inaccurate for the tolerance.
            results.append(result("sloppy", .auto, language, errors: 9, elapsed: 0.05))
        }
        // English only: cannot be picked when Italian is required.
        results.append(result("english", .auto, "en", errors: 0, elapsed: 0.01))
        let summaries = SpeechBenchmarkReport.summaries(results)
        let picks = SpeechBenchmarkReport.picks(summaries, runs: [run("accurate", peak: 2_000_000_000), run("balanced", peak: 1_000_000_000), run("sloppy", peak: 500_000_000)])
        XCTAssertEqual(picks.best?.model, "accurate")
        XCTAssertEqual(picks.standard?.model, "balanced", "The default must detect the language on its own")
        XCTAssertEqual(picks.fastest?.model, "balanced", "Within 50% of the best error rate")
        XCTAssertEqual(picks.languages, ["en", "es", "it"])
        var strict = SpeechBenchmarkReport.Limits(); strict.memory = 800_000_000
        let lean = SpeechBenchmarkReport.picks(summaries, runs: [run("balanced", peak: 1_000_000_000), run("sloppy", peak: 500_000_000)], limits: strict)
        XCTAssertEqual(lean.standard?.model, "sloppy", "Balanced needs more memory than the limit allows")
        let report = SpeechBenchmarkReport.markdown(summaries, runs: [run("balanced", peak: 1_000_000_000)])
        XCTAssertTrue(report.contains("**Default:** balanced (auto)"))
        XCTAssertTrue(report.contains("| it |") || report.contains("| en | it |"))
    }
    func testARepeatedClipCountsOnceWithItsLatestResult() {
        let first = SpeechBenchmarkResult(model: "m", mode: .auto, clip: "it-1", kind: .speech, language: "it", seconds: 10, elapsed: 0.5, text: "", words: EditCounts(substitutions: 5, reference: 10), formatted: EditCounts(reference: 10))
        let again = SpeechBenchmarkResult(model: "m", mode: .auto, clip: "it-1", kind: .speech, language: "it", seconds: 10, elapsed: 0.2, text: "", words: EditCounts(substitutions: 1, reference: 10), formatted: EditCounts(reference: 10))
        let summary = SpeechBenchmarkReport.summaries([first, again])[0]
        XCTAssertEqual(summary.errorRate["it"]!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(summary.latency50!, 0.2, accuracy: 1e-9)
    }
    func testNonSpeechCountsWordsPerClip() {
        let summaries = SpeechBenchmarkReport.summaries([
            SpeechBenchmarkResult(model: "m", mode: .auto, clip: "silence", kind: .nonspeech, language: "und", seconds: 3, elapsed: 0.1, text: "thank you", words: EditCounts(insertions: 2), formatted: EditCounts(insertions: 2)),
            SpeechBenchmarkResult(model: "m", mode: .auto, clip: "hum", kind: .nonspeech, language: "und", seconds: 3, elapsed: 0.1, text: "", words: EditCounts(), formatted: EditCounts())
        ])
        XCTAssertEqual(summaries[0].nonspeechWords, 1)
        XCTAssertTrue(summaries[0].errorRate.isEmpty)
    }
    func testManifestAndResultLinesRoundTrip() throws {
        let clip = SpeechBenchmarkClip(id: "fleurs-it-1", source: "fleurs", kind: .long, language: "it", audio: ["a.wav", "b.wav"], reference: "Ciao. Come stai?", seconds: 12.4)
        let encoded = try JSONEncoder().encode(clip)
        XCTAssertEqual(try SpeechBenchmarkClip.manifest(encoded + Data("\n\n".utf8) + encoded), [clip, clip])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let lines = try encoder.encode(SpeechBenchmarkLine(run: run("m", peak: 1))) + Data("\n".utf8) + encoder.encode(SpeechBenchmarkLine(result: result("m", .auto, "it", errors: 1, elapsed: 0.2)))
        let read = try SpeechBenchmarkLine.read(lines)
        XCTAssertEqual(read.runs.count, 1); XCTAssertEqual(read.results.count, 1)
    }
}

final class SpokenNumberTests: XCTestCase {
    private func read(_ text: String, _ language: String) -> String { SpokenNumbers.digits(text.split(separator: " ").map(String.init), language: language).joined(separator: " ") }

    func testItalian() {
        XCTAssertEqual(read("duemilacinquecento", "it"), "2500")
        XCTAssertEqual(read("millenovecentottantasette", "it"), "1987")
        XCTAssertEqual(read("ventuno trentotto centottanta ventitré", "it"), "21 38 180 23")
        XCTAssertEqual(read("un milione duecentomila", "it"), "1200000")
        XCTAssertEqual(read("tre e quattro", "it"), "3 e 4", "Two numbers joined by \"e\" stay two")
        XCTAssertEqual(read("alle venti e trenta", "it"), "alle 20 e 30")
        XCTAssertEqual(read("la quarantena di milano", "it"), "la quarantena di milano", "Words that only start like numbers stay words")
    }
    func testEnglish() {
        XCTAssertEqual(read("one hundred and five", "en"), "105")
        XCTAssertEqual(read("a hundred people", "en"), "100 people")
        XCTAssertEqual(read("a dog", "en"), "a dog")
        XCTAssertEqual(read("two thousand five hundred", "en"), "2500")
        XCTAssertEqual(read("twenty twenty six", "en"), "2026")
        XCTAssertEqual(read("one two three", "en"), "1 2 3")
        XCTAssertEqual(read("and then twenty and nothing", "en"), "and then 20 and nothing")
    }
    func testGerman() {
        XCTAssertEqual(read("fünfundzwanzig", "de"), "25")
        XCTAssertEqual(read("zweitausendfünfhundert", "de"), "2500")
        XCTAssertEqual(read("neunzehnhundertneunundneunzig", "de"), "1999")
        XCTAssertEqual(read("dreizehn", "de"), "13")
        XCTAssertEqual(read("fünf zwanzig", "de"), "5 20", "Without und, a unit and a ten are two numbers")
    }
    func testFrench() {
        XCTAssertEqual(read("quatre vingt dix", "fr"), "90")
        XCTAssertEqual(read("soixante et onze", "fr"), "71")
        XCTAssertEqual(read("dix sept", "fr"), "17")
        XCTAssertEqual(read("soixante dix sept", "fr"), "77")
        XCTAssertEqual(read("mille neuf cent quatre vingt sept", "fr"), "1987")
        XCTAssertEqual(read("deux cents", "fr"), "200")
    }
    func testSpanishAndPortuguese() {
        XCTAssertEqual(read("veintiuno", "es"), "21")
        XCTAssertEqual(read("treinta y cinco", "es"), "35")
        XCTAssertEqual(read("mil novecientos ochenta y siete", "es"), "1987")
        XCTAssertEqual(read("ciento veinte", "es"), "120")
        XCTAssertEqual(read("vinte e cinco", "pt"), "25")
        XCTAssertEqual(read("dois mil e quinhentos", "pt"), "2500")
        XCTAssertEqual(read("cento e vinte", "pt"), "120")
    }
    func testOtherLanguagesKeepTheirWords() {
        XCTAssertEqual(read("twee en twintig", "nl"), "twee en twintig")
    }
}
