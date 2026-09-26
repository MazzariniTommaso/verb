import Foundation

/// Code said out loud, for editors and terminals. "user id" becomes `userId` when the project
/// has it, "camel case user id" becomes `userId` anyway, "app model punto swift" becomes
/// AppModel.swift, and "tag index dot ts" becomes @index.ts, or @src/index.ts in a terminal,
/// where Claude Code and Codex read paths from the folder they run in.
public enum CodeSpeech {
    /// What the project holds: its identifiers, with how often each appears, and its files,
    /// as paths from the project's folder.
    public struct Index: Sendable, Equatable {
        public var identifiers: [String: Int]
        public var files: [String]
        public init(identifiers: [String: Int] = [:], files: [String] = []) { self.identifiers = identifiers; self.files = files }
    }

    /// Folders never worth reading: dependencies, builds and caches.
    static let skipped: Set<String> = ["node_modules", ".build", "build", "dist", "DerivedData", "Pods", "vendor", "target", ".git", ".venv", "venv", "__pycache__",
                                       ".next", ".gradle", "out", ".swiftpm", "Carthage", ".idea", ".vscode", "coverage", ".cache", "release"]
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "mjs", "py", "go", "rs", "java", "kt", "kts", "rb", "php",
                                                "cs", "scala", "dart", "vue", "svelte", "lua", "sh", "sql", "ex", "exs", "clj", "hs", "ml", "zig"]
    /// Signs that a folder is a project's top.
    static let markers = [".git", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Gemfile", "build.gradle", "pom.xml", "composer.json"]

    /// The project a file or folder belongs to: the nearest folder above it with a marker such
    /// as .git or Package.swift, or the folder itself.
    public static func root(of url: URL) -> URL? {
        // Standardized first: a path with ".." has itself as its parent and would never reach the top.
        let standard = url.standardizedFileURL
        var folder = standard.hasDirectoryPath ? standard : standard.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let candidate = folder
        while folder.path.count > 1, folder.path != home {
            if markers.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return folder }
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true { return folder }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            guard parent.path != folder.path else { break }
            folder = parent
        }
        return candidate.path == home ? nil : candidate
    }

    /// Reads a project: every file's path, and the identifiers of its source files, as far as
    /// `fileLimit` files. Compound names only (userId, user_id, AppModel): plain words are
    /// speech already.
    public static func index(root: URL, fileLimit: Int = 20_000) -> Index {
        var index = Index()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsPackageDescendants]) else { return index }
        let base = root.standardizedFileURL.path + "/"
        let pattern = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]{3,60}\b"#)
        var read = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skipped.contains(name) || (name.hasPrefix(".") && name != ".github") { walker.skipDescendants() }
                continue
            }
            guard !name.hasPrefix(".") else { continue }
            let path = url.standardizedFileURL.path
            index.files.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : name)
            if index.files.count >= fileLimit { break }
            guard sourceExtensions.contains(url.pathExtension.lowercased()), (values?.fileSize ?? 0) <= 300_000, read < 4_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            read += 1
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: match.range)
                guard isCompound(word) else { continue }
                index.identifiers[word, default: 0] += 1
            }
        }
        // The most used are enough to recognise.
        if index.identifiers.count > 5_000 {
            index.identifiers = Dictionary(uniqueKeysWithValues: index.identifiers.sorted { $0.value > $1.value }.prefix(5_000).map { ($0.key, $0.value) })
        }
        return index
    }

    /// camelCase, PascalCase with two parts or more, or snake_case.
    static func isCompound(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 4, !letters.allSatisfy(\.isUppercase) || word.contains("_") else { return false }
        if word.contains("_") { return word.split(separator: "_").filter { !$0.isEmpty }.count >= 2 }
        return word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    /// The spoken words to replace, each with its code, longest first. The caller treats them
    /// like snippets, so a writing model never touches the code. `mentionPaths` is for
    /// terminals, where "at index dot ts" mentions @src/index.ts; in an editor "at" stays a
    /// word. `isOrdinary` says whether a word is a common one, which stays a word: "the setup"
    /// never becomes `setUp`, though the project has it.
    public static func replacements(in text: String, index: Index?, mentionPaths: Bool, isOrdinary: (String) -> Bool = { _ in false }) -> [(spoken: String, code: String)] {
        let words = tokens(text)
        guard !words.isEmpty else { return [] }
        var taken = Array(repeating: false, count: words.count)
        var found: [(spoken: String, code: String)] = []
        func claim(_ range: ClosedRange<Int>, code: String) {
            guard !range.contains(where: { taken[$0] }) else { return }
            for i in range { taken[i] = true }
            let spoken = String(text[words[range.lowerBound].range.lowerBound..<words[range.upperBound].range.upperBound])
            if spoken != code { found.append((spoken, code)) }
        }
        // Files first: "tag app model punto swift", "index dot ts", "index.ts". "At" is a word
        // like any other in an editor; only a terminal reads it as the mention.
        let triggers: Set<String> = mentionPaths ? ["tag", "at", "chiocciola"] : ["tag", "chiocciola"]
        if let index, !index.files.isEmpty {
            var byName: [String: [String]] = [:]
            for path in index.files { byName[key((path as NSString).lastPathComponent), default: []].append(path) }
            for dot in words.indices where ["punto", "dot"].contains(words[dot].lower) && dot + 1 < words.count && dot > 0 {
                let ext = words[dot + 1].lower
                for count in stride(from: min(3, dot), through: 1, by: -1) {
                    let start = dot - count
                    let name = words[start..<dot].map(\.lower).joined() + "." + ext
                    guard let paths = byName[key(name)], let path = paths.min(by: { $0.count < $1.count }) else { continue }
                    let mention = start > 0 && (triggers.contains(words[start - 1].lower) || words[start - 1].lower == "@")
                    claim((mention ? start - 1 : start)...(dot + 1), code: mention ? "@" + (mentionPaths ? path : (path as NSString).lastPathComponent) : (path as NSString).lastPathComponent)
                    break
                }
            }
            // Written with the dot already: put the case right, and the @ when asked for.
            for i in words.indices where words[i].text.contains(".") && !taken[i] {
                guard let paths = byName[key(words[i].text)], let path = paths.min(by: { $0.count < $1.count }) else { continue }
                let triggered = i > 0 && triggers.contains(words[i - 1].lower)
                let mention = triggered || words[i].text.hasPrefix("@")
                claim((triggered ? i - 1 : i)...i, code: mention ? "@" + (mentionPaths ? path : (path as NSString).lastPathComponent) : (path as NSString).lastPathComponent)
            }
        }
        // "camel case user id", "snake case retry count", "constant case max size". Said about
        // a case instead ("handle the constant case first"), the words stay: after an article,
        // or with a single common word inside a sentence.
        for i in words.indices where !taken[i] {
            let style: String?
            if i + 1 < words.count, words[i + 1].lower == "case", ["camel", "pascal", "snake", "kebab", "constant"].contains(words[i].lower) { style = words[i].lower }
            else { style = nil }
            guard let style else { continue }
            let inside = i > 0 && !text[words[i - 1].range.upperBound..<words[i].range.lowerBound].contains { ".!?:;\n".contains($0) }
            if inside, articles.contains(words[i - 1].lower) { continue }
            var parts: [Int] = []
            var j = i + 2
            while j < words.count, parts.count < 4, !stopwords.contains(words[j].lower), !taken[j] {
                parts.append(j)
                // A comma or a full stop right after a word ends the name.
                if let next = text[words[j].range.upperBound...].first, ",.;:!?".contains(next) { break }
                j += 1
            }
            guard let last = parts.last else { continue }
            if inside, parts.count == 1, isOrdinary(words[last].text) || isOrdinary(words[last].lower) { continue }
            claim(i...last, code: cased(parts.map { words[$0].lower }, style: style))
        }
        // Names the project uses, said as words: "user id" is userId there.
        if let index, !index.identifiers.isEmpty {
            var byKey: [String: (String, Int)] = [:]
            for (identifier, count) in index.identifiers {
                let k = key(identifier)
                if let current = byKey[k], current.1 >= count { continue }
                byKey[k] = (identifier, count)
            }
            for length in stride(from: 4, through: 2, by: -1) {
                var i = 0
                while i + length <= words.count {
                    let range = i...(i + length - 1)
                    let parts = range.map { words[$0] }
                    let joined = parts.map(\.lower).joined()
                    let spaced = zip(parts, parts.dropFirst()).allSatisfy { text[$0.range.upperBound..<$1.range.lowerBound].allSatisfy { $0 == " " } }
                    if spaced, joined.count >= 6, !parts.contains(where: { stopwords.contains($0.lower) }), let match = byKey[key(joined)], match.1 >= 2, !range.contains(where: { taken[$0] }) {
                        claim(range, code: match.0); i += length
                    } else { i += 1 }
                }
            }
            // One word that is a project name in the wrong case: "appmodel" is AppModel. A common
            // word stays a word: "the setup" and "the login", though the project has setUp and logIn.
            for i in words.indices where !taken[i] && words[i].text.count >= 5 {
                guard let match = byKey[key(words[i].text)], match.1 >= 2, match.0 != words[i].text, isCompound(match.0), !isOrdinary(words[i].text), !isOrdinary(words[i].lower) else { continue }
                claim(i...i, code: match.0)
            }
        }
        return found.sorted { $0.spoken.count > $1.spoken.count }
    }

    /// Words that make a case command a case spoken about: "the constant case".
    static let articles: Set<String> = ["the", "a", "an", "this", "that", "each", "every", "any", "il", "lo", "la", "un", "uno", "una", "questo", "questa", "quel", "quello", "quella"]
    /// Words that are never part of a name: they join the name to the rest of the sentence.
    static let stopwords: Set<String> = ["e", "o", "il", "lo", "la", "i", "gli", "le", "un", "una", "di", "del", "della", "dei", "da", "in", "con", "per", "su", "che", "poi", "nel", "nella", "è",
                                         "and", "or", "the", "a", "an", "of", "to", "in", "on", "for", "with", "is", "it", "this", "that", "then", "at", "by", "as", "from"]

    static func cased(_ parts: [String], style: String) -> String {
        switch style {
        case "snake": return parts.joined(separator: "_")
        case "kebab": return parts.joined(separator: "-")
        case "constant": return parts.joined(separator: "_").uppercased()
        case "pascal": return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        default: return (parts.first ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }
    /// Letters and digits only, lowercased: "user_id", "userId" and "user id" meet here.
    static func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." } }

    struct Word { let text: String; let lower: String; let range: Range<String.Index> }
    static func tokens(_ text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isLetter || text[index].isNumber || text[index] == "_" || text[index] == "@" {
                var end = index
                // A dot inside a word belongs to it: "index.ts".
                while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" || text[end] == "@" || (text[end] == "." && text.index(after: end) < text.endIndex && (text[text.index(after: end)].isLetter || text[text.index(after: end)].isNumber)) {
                    end = text.index(after: end)
                }
                let word = String(text[index..<end])
                words.append(Word(text: word, lower: word.lowercased(), range: index..<end))
                index = end
            } else { index = text.index(after: index) }
        }
        return words
    }
}
