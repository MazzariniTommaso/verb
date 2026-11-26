import AppKit
import ApplicationServices
import CoreAudio
import VerbCore
import VerbEngine

/// The answer to a request made with the command keys, or what an action found, shown in a card
/// over the overlay until it is closed, used, or a new dictation begins.
struct AnswerCard: Equatable, Identifiable {
    let id = UUID()
    /// What was asked, as heard.
    var request: String
    /// The answer so far, in Markdown.
    var text = ""
    /// Still coming from the model.
    var streaming = false
    /// Files that matched a search, to open.
    var files: [URL] = []
    /// Something went wrong: what to say instead of an answer.
    var problem: String?
    /// The answer can go into the field the request was made in.
    var canInsert = false
}

/// The first dictation in an app, with Verb beside you: click into the field, then speak.
enum CoachStep: Equatable {
    case click(app: String, bundleID: String)
    case speak(app: String, bundleID: String)
    case done(app: String)
}

/// The parts of a long recording written down while it still records, cut where the final pass
/// cuts them, so the text at the end is the same and only the last part is left to do.
@MainActor final class TranscriptAhead {
    let id: UUID
    let variant: String
    let language: DictationLanguage
    let vocabulary: [VocabularyEntry]
    private(set) var texts: [String] = []
    private(set) var detected: String?
    /// Where in the recording, in samples, the parts written down end.
    private(set) var offset = 0
    private var work: Task<Void, Never>?
    private var stopped = false
    init(id: UUID, variant: String, language: DictationLanguage, vocabulary: [VocabularyEntry]) { self.id = id; self.variant = variant; self.language = language; self.vocabulary = vocabulary }

    /// Takes the next part when a whole one has been recorded and the engine is free of it.
    func step(recorder: Recorder, speech: LocalSpeech) {
        guard !stopped, work == nil else { return }
        let (samples, end) = recorder.take(from: offset)
        // The recording kept in memory no longer reaches back here: the end does the rest.
        guard end - samples.count <= offset else { stopped = true; return }
        let part = 16000 * 28
        guard samples.count > part else { return }
        guard let first = SpeechChunking.ranges(samples: Array(samples.prefix(part + 1)), sampleRate: 16000).first, first.upperBound < samples.count else { return }
        // As the file holds them, in 16 bits, so the part reads exactly as the final pass would read it.
        let slice = samples[first].map { max(-32768, min(32767, ($0 * 32768).rounded())) / 32768 }, start = offset
        work = Task { [weak self] in
            guard let self else { return }
            let result = try? await speech.decodePart(samples: slice, variant: self.variant, language: self.language, vocabulary: self.vocabulary)
            self.work = nil
            guard !self.stopped, self.offset == start else { return }
            guard let result else { self.stopped = true; return }
            self.texts.append(result.text); self.detected = result.language ?? self.detected
            self.offset = start + first.upperBound
        }
    }
    /// Waits for the part under way, then says what is done.
    func settle() async -> (texts: [String], detected: String?, offset: Int) {
        await work?.value
        stopped = true
        return (texts, detected, offset)
    }
    func cancel() { stopped = true; work?.cancel() }
}

/// Apps installed on this Mac, by the names people say: "Slack", "Impostazioni di Sistema", "Calendario".
@MainActor enum AppFinder {
    private static var known: [(names: [String], url: URL)]?
    static func find(_ spoken: String) -> URL? {
        let wanted = TextRules.canonical(spoken).lowercased().replacingOccurrences(of: " app", with: "")
        guard !wanted.isEmpty else { return nil }
        let apps = all()
        if let exact = apps.first(where: { $0.names.contains(wanted) }) { return exact.url }
        if let start = apps.filter({ $0.names.contains { $0.hasPrefix(wanted + " ") } }).min(by: { $0.url.lastPathComponent.count < $1.url.lastPathComponent.count }) { return start.url }
        let close = apps.compactMap { app -> (URL, Double)? in
            let best = app.names.map { Double(CorrectionLearner.distance($0, wanted)) / Double(max($0.count, wanted.count)) }.min() ?? 1
            return best <= 0.25 ? (app.url, best) : nil
        }.sorted { $0.1 < $1.1 }
        return close.first?.0
    }
    private static func all() -> [(names: [String], url: URL)] {
        if let known { return known }
        let manager = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var found: [(names: [String], url: URL)] = []
        for folder in folders {
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                let names = Set([String(name.dropLast(4)), manager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")].map { TextRules.canonical($0).lowercased() })
                found.append((Array(names), url))
            }
        }
        known = found
        return found
    }
}

/// Files that match a request, through Spotlight, most recently used first.
@MainActor enum FileSearch {
    static func find(_ words: String, limit: Int = 8) async -> [URL] {
        let terms = words.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [] }
        let query = NSMetadataQuery()
        let byName = terms.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        let byText = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemTextContentKey, words)
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [NSCompoundPredicate(andPredicateWithSubpredicates: byName), byText])
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        return await withCheckedContinuation { continuation in
            var finished = false
            func done() {
                guard !finished else { return }
                finished = true
                query.stop()
                let results = (query.results as? [NSMetadataItem] ?? []).compactMap { ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) } }
                // Names first, then contents: a file named for the words is the likelier one.
                let named = results.filter { url in terms.allSatisfy { url.lastPathComponent.localizedCaseInsensitiveContains($0) } }
                continuation.resume(returning: Array((named + results.filter { !named.contains($0) }).filter { !$0.lastPathComponent.hasPrefix(".") }.prefix(limit)))
            }
            let observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in MainActor.assumeIsolated { done() } }
            query.start()
            Task { @MainActor in try? await Task.sleep(nanoseconds: 2_500_000_000); done(); NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// What a window shows, read through Accessibility for a request's context: its text, a little
/// of it, in the order it appears. Password fields are skipped and nothing is kept.
@MainActor enum ScreenText {
    static func read(pid: pid_t, limit: Int = 6000) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = TextTarget.element(TextTarget.attribute(app, kAXFocusedWindowAttribute)) else { return nil }
        var queue = [window], seen = 0, lines: [String] = [], length = 0
        let started = Date()
        while !queue.isEmpty, seen < 800, length < limit, Date().timeIntervalSince(started) < 0.4 {
            let element = queue.removeFirst(); seen += 1
            let role = TextTarget.attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = TextTarget.attribute(element, kAXSubroleAttribute) as? String ?? ""
            if subrole == kAXSecureTextFieldSubrole { continue }
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink"].contains(role), let value = (TextTarget.attribute(element, kAXValueAttribute) as? String) ?? (TextTarget.attribute(element, kAXTitleAttribute) as? String) {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 2, lines.last != text { lines.append(text); length += text.count }
            }
            if let children = TextTarget.attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(60)) }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }
}

/// The website a browser shows, from its page's address or else from its window's title.
@MainActor enum SiteReader {
    static func site(of target: TextTarget?) -> Site? {
        guard let target, Places.browsers.contains(target.bundleID) else { return nil }
        if let element = target.element, let url = pageURL(above: element) { return Places.site(url: url) }
        if let url = pageURL(inWindowOf: target.pid) { return Places.site(url: url) }
        return target.title.flatMap(Places.site(title:))
    }
    /// The address of the page the element is in, found by going up to its web area.
    static func pageURL(above element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if TextTarget.attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { return url(of: node) }
            current = TextTarget.element(TextTarget.attribute(node, kAXParentAttribute))
        }
        return nil
    }
    /// The address of the page in the app's focused window: its first web area.
    static func pageURL(inWindowOf pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = TextTarget.element(TextTarget.attribute(app, kAXFocusedWindowAttribute)) else { return nil }
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 300 {
            let node = queue.removeFirst(); seen += 1
            if TextTarget.attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { return url(of: node) }
            if let children = TextTarget.attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(30)) }
        }
        return nil
    }
    private static func url(of node: AXUIElement) -> URL? {
        guard let value = TextTarget.attribute(node, "AXURL") else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        return (value as? String).flatMap(URL.init(string:))
    }
}

/// The apps using a microphone now, other than Verb, by bundle identifier and process.
enum MicrophoneUsers {
    static func now() -> [(bundleID: String, pid: pid_t)] {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) }
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else { return [] }
        let own = getpid()
        return processes.compactMap { process in
            var pid = pid_t(0), pidSize = UInt32(MemoryLayout<pid_t>.size), running = UInt32(0), runningSize = UInt32(MemoryLayout<UInt32>.size)
            var pidAddress = address(kAudioProcessPropertyPID), runningAddress = address(kAudioProcessPropertyIsRunningInput), bundleAddress = address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != own,
                  AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?, bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let id = AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr ? (bundle?.takeRetainedValue() as String?) : nil
            return ((id?.isEmpty == false ? id : nil) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "", pid)
        }
    }
}
