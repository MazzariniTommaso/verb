import Foundation

/// English words the speech engine wrote the Italian way, put back: "mercio" for merge,
/// "bundolo" for bundle, "Warcher" for Watcher. Only words that exist in neither language
/// are looked at, and only an English word you use, a dictionary word or a common term of
/// the trade can take their place, when it sounds or reads almost the same. Names stay:
/// "Sara", "Modena" and "Diego" are known with their capital, and a capitalised word inside
/// a sentence that nothing knows is taken for a name unless it is close to a word of yours.
public enum EnglishTerms {
    /// English terms of software and office work that come up inside Italian sentences.
    public static let trade: Set<String> = [
        "merge", "commit", "push", "pull", "branch", "deploy", "build", "release", "feature", "bug", "fix", "test", "bundle", "tier", "cache", "query", "endpoint",
        "token", "prompt", "overlay", "shortcut", "framework", "library", "package", "dependency", "workflow", "pipeline", "dashboard", "backend", "frontend", "database",
        "dataset", "server", "client", "cluster", "container", "docker", "script", "runtime", "thread", "callback", "handler", "payload", "schema", "parser", "compiler",
        "debug", "debugger", "logging", "trace", "stack", "array", "string", "boolean", "object", "class", "struct", "protocol", "interface", "method", "function",
        "variable", "parameter", "argument", "index", "value", "filter", "reduce", "hash", "markdown", "repository", "fork", "rebase", "stash", "checkout", "issue",
        "ticket", "sprint", "backlog", "standup", "meeting", "call", "email", "slack", "notion", "figma", "design", "layout", "mockup", "wireframe", "render",
        "component", "state", "hook", "router", "route", "middleware", "login", "logout", "password", "user", "admin", "role", "permission", "staging", "production",
        "rollback", "hotfix", "patch", "version", "update", "upgrade", "install", "setup", "config", "settings", "toggle", "button", "click", "scroll", "swipe", "drag",
        "drop", "select", "input", "output", "feedback", "review", "approve", "reject", "conflict", "diff", "benchmark", "performance", "latency", "throughput",
        "scaling", "load", "balancer", "proxy", "gateway", "webhook", "watcher", "engine", "memory", "brain", "agent", "model", "training", "inference", "embedding",
        "vector", "cloud", "deadline", "budget", "business", "startup", "founder", "pitch", "deck", "roadmap", "milestone", "task", "team", "manager", "lead", "call",
        "check", "report", "insight", "insights", "tracking", "event", "trigger", "action", "flow", "flowchart", "onboarding", "offboarding", "coding", "developer",
        "refactor", "refactoring", "linter", "formatter", "plugin", "extension", "terminal", "shell", "folder", "file", "upload", "download", "sync", "backup",
    ]

    /// The text with Italian-sounding misspellings of English words replaced, and how many.
    /// `lexicon` holds the words you use (from History, the dictionary, the field); `known`
    /// says whether a word exists in Italian or English, asked with the word's own casing, so
    /// it knows "Sara" and not "sara"; `isEnglish` whether it is English and not also Italian,
    /// for words of the lexicon that aren't trade terms.
    public static func restore(_ text: String, lexicon: [String: Int], preferred: Set<String> = [], known: (String) -> Bool, isEnglish: (String) -> Bool) -> (text: String, changes: Int) {
        let pattern = try! NSRegularExpression(pattern: #"\p{L}{4,}"#)
        let ns = text as NSString
        var result = text, changes = 0
        var uses: [String: Int] = [:]
        for (word, count) in lexicon { uses[word.lowercased(), default: 0] += count }
        let candidates = Set(uses.keys).union(trade).union(preferred.map { $0.lowercased() })
        let spelled = Dictionary(preferred.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range), lower = word.lowercased()
            // History holds the misspellings too: a word counts as right only when it is a trade term, a dictionary spelling or a known word.
            // A name is known only with its capital, and a name the engine wrote in lowercase ("sergio") is still a name.
            guard !trade.contains(lower), spelled[lower] == nil, !known(word), !known(lower), !known(word.prefix(1).uppercased() + lower.dropFirst()) else { continue }
            // A capital inside a sentence marks a name ("con Kiara"): only a word of yours can take its place, never a trade term alone.
            let named = word.first?.isUppercase == true && !opensSentence(ns.substring(to: match.range.location))
            let allowed: (String) -> Bool = named
                ? { spelled[$0] != nil || ((uses[$0] ?? 0) > 0 && (trade.contains($0) || isEnglish($0))) }
                : { trade.contains($0) || spelled[$0] != nil || isEnglish($0) }
            guard let best = closest(to: lower, among: candidates, uses: uses, allowed: allowed) else { continue }
            var replacement = spelled[best] ?? best
            if spelled[best] == nil, word.first?.isUppercase == true { replacement = replacement.prefix(1).uppercased() + replacement.dropFirst() }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            changes += 1
        }
        return (result, changes)
    }

    /// Whether a word after `before` opens a sentence, where a capital says nothing.
    static func opensSentence(_ before: String) -> Bool {
        for character in before.reversed() {
            if character.isNewline { return true }
            if character.isWhitespace || "\"“‘«([".contains(character) { continue }
            return ".!?…".contains(character)
        }
        return true
    }

    /// The one candidate that reads or sounds almost like the word, if there is one.
    static func closest(to word: String, among candidates: Set<String>, uses: [String: Int] = [:], allowed: (String) -> Bool) -> String? {
        let heard = Array(word), heardKey = Array(italianKey(word))
        var scored: [(String, Double)] = []
        for candidate in candidates where candidate != word && abs(candidate.count - word.count) <= 3 {
            // An English verb made Italian ("fixa", "pushare", "committato") is meant that way.
            let stem = candidate.hasSuffix("e") ? String(candidate.dropLast()) : candidate
            if [candidate, stem].contains(where: { word.hasPrefix($0) && italianEndings.contains(String(word.dropFirst($0.count))) }) { return nil }
            let byLetters = distance(heard, Array(candidate))
            let bySound = distance(heardKey, Array(englishKey(candidate)))
            // The words you use often win over a trade term that sounds as close.
            let score = min(byLetters, bySound) - 0.25 * log2(1 + Double(uses[candidate] ?? 0))
            if min(byLetters, bySound) <= 1.0 { scored.append((candidate, score)) }
        }
        scored.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        guard let best = scored.first, scored.dropFirst().first.map({ $0.1 >= best.1 + 0.5 }) ?? true, allowed(best.0) else { return nil }
        return best.0
    }

    /// Endings that make an English word Italian: "fix" into "fixa", "fixare", "fixato".
    static let italianEndings: Set<String> = ["a", "o", "i", "e", "are", "are", "ato", "ata", "ati", "ate", "ando", "iamo", "ano", "ino", "ava", "avo", "avano", "ero", "era",
                                              "erei", "iare", "iato", "iata", "tare", "tato", "ta", "to", "ti", "iamo", "ate", "no", "rei"]
    /// How an Italian reads the word aloud, written with one letter per sound: C for the
    /// "ci" sound, J for "gi", S for "sci".
    static func italianKey(_ word: String) -> String {
        var s = word.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        for (pattern, replacement) in [("gli", "l"), ("gn", "n"), ("sc(?=[ei])", "S"), ("ch", "k"), ("gh", "g"), ("ci(?=[aou])", "C"), ("c(?=[ei])", "C"),
                                       ("gi(?=[aou])", "J"), ("g(?=[ei])", "J"), ("qu", "kw"), ("c", "k"), ("h", ""), ("z", "ts"), ("y", "i"), ("w", "u"), ("x", "ks"), ("j", "J")] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        s = collapsed(s)
        // Italian adds a vowel to words that end on a consonant: "bundolo" for bundle.
        if s.count > 3, let last = s.last, "aeiou".contains(last) { s.removeLast() }
        return s
    }

    /// Roughly how the English word sounds, in the same letters.
    static func englishKey(_ word: String) -> String {
        var s = word.lowercased()
        for (pattern, replacement) in [("tch", "C"), ("dge", "J"), ("ch", "C"), ("sh", "S"), ("th", "t"), ("ph", "f"), ("ck", "k"), ("qu", "kw"), ("wh", "u"), ("igh", "ai"), ("gh", ""),
                                       ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ou", "au"), ("ow", "au"), ("ai", "e"), ("ay", "e"), ("g(?=[eiy])", "J"), ("c(?=[eiy])", "s"),
                                       ("c", "k"), ("x", "ks"), ("w", "u"), ("y", "i"), ("j", "J"), ("le$", "l"), ("(?<=[^aeiou])e$", "")] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return collapsed(s)
    }

    private static func collapsed(_ s: String) -> String {
        var out = ""
        for character in s where out.last != character { out.append(character) }
        return out
    }

    /// Letters to change, add or remove, where a vowel counts half, a voiced and a voiceless
    /// pair (C and J, t and d, k and g) count half, and two vowels three quarters.
    static func distance(_ a: [Character], _ b: [Character]) -> Double {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        let pairs: Set<String> = ["CJ", "JC", "td", "dt", "kg", "gk", "pb", "bp", "fv", "vf", "sz", "zs", "SC", "CS"]
        func substitution(_ x: Character, _ y: Character) -> Double {
            if x == y { return 0 }
            if vowels.contains(x) && vowels.contains(y) { return 0.75 }
            return pairs.contains(String([x, y])) ? 0.5 : 1
        }
        func gap(_ x: Character) -> Double { vowels.contains(x) ? 0.5 : 1 }
        guard !a.isEmpty else { return b.map(gap).reduce(0, +) }
        guard !b.isEmpty else { return a.map(gap).reduce(0, +) }
        var previous = [0.0] + b.indices.map { b[...$0].map(gap).reduce(0, +) }
        for i in 1...a.count {
            var current = [previous[0] + gap(a[i - 1])]
            for j in 1...b.count {
                current.append(min(previous[j] + gap(a[i - 1]), current[j - 1] + gap(b[j - 1]), previous[j - 1] + substitution(a[i - 1], b[j - 1])))
            }
            previous = current
        }
        return previous[b.count]
    }
}
