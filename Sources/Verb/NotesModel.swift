import AppKit
import AVFoundation
import UniformTypeIdentifiers
import NaturalLanguage
import VerbCore
import VerbEngine

/// A meeting being recorded, or written down after it.
enum MeetingState: Equatable {
    case idle
    case recording(Date)
    /// What Verb is doing with it, in the interface's words.
    case writing(String)
}

/// The note editor with the cursor in it. While Verb itself is in front, a dictation, a voice
/// edit or a transform goes here instead of being pasted.
@MainActor protocol NoteEditing: AnyObject {
    var isEditing: Bool { get }
    var selectedText: String { get }
    var text: String { get }
    /// Puts the text at the cursor, in place of the selection.
    func insert(_ text: String)
    func selectAll()
    /// The welcome's practice sheet rather than a note.
    var isPractice: Bool { get }
    /// A note or the practice sheet, rather than any other field of Verb's.
    var isNote: Bool { get }
}
extension NoteEditing {
    var isPractice: Bool { false }
    var isNote: Bool { true }
    /// What History says a dictation did here.
    var delivery: String { isPractice ? "Written on the practice sheet" : isNote ? "Written in your note" : "Written in Verb" }
}

/// Any other field of Verb's with the keys: a setting, a word in the dictionary, a snippet, a
/// prompt, a search. Verb writes into it directly, as into a note, rather than pasting into itself.
@MainActor final class OwnField: NoteEditing {
    private weak var view: NSTextView?
    /// The key window's field being edited, or nil.
    init?(_ responder: NSResponder?) {
        guard let view = responder as? NSTextView, view.isEditable, view.window?.isKeyWindow == true else { return nil }
        self.view = view
    }
    var isEditing: Bool { view.map { $0.window?.firstResponder === $0 } ?? false }
    var selectedText: String {
        guard let view else { return "" }
        let range = view.selectedRange(), whole = view.string as NSString
        return NSMaxRange(range) <= whole.length ? whole.substring(with: range) : ""
    }
    var text: String { view?.string ?? "" }
    var isNote: Bool { false }
    func insert(_ text: String) {
        guard let view else { return }
        // A one-line field takes the lines as one. Typed in this way, the field's own binding and undo follow.
        let words = view.isFieldEditor ? text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ") : text
        view.insertText(words, replacementRange: view.selectedRange())
    }
    func selectAll() { view?.selectAll(nil) }
}

extension AppModel {
    /// Where the notes are kept: the folder chosen in Settings, or Verb's own.
    var notesFolder: URL { settings.notesPath.isEmpty ? paths.root.appendingPathComponent("Notes", isDirectory: true) : URL(fileURLWithPath: settings.notesPath, isDirectory: true) }
    /// A folder you chose that can't be read now, as iCloud offline or a disk unplugged: Notes
    /// says so rather than looking empty. Verb's own folder is made when the first note is.
    var notesFolderUnreachable: Bool {
        guard !settings.notesPath.isEmpty else { return false }
        var directory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: notesFolder.path, isDirectory: &directory) || !directory.boolValue || !FileManager.default.isReadableFile(atPath: notesFolder.path)
    }
    /// What takes Verb's words directly while Verb is in front: the note being edited, or any
    /// other field of Verb's with the keys.
    var ownEditor: NoteEditing? {
        guard NSApp.isActive else { return nil }
        if let noteEditor, noteEditor.isEditing { return noteEditor }
        return OwnField(NSApp.keyWindow?.firstResponder)
    }

    func reloadNotes() {
        let fresh = NotesStore.list(in: notesFolder)
        if fresh != notes { notes = fresh }
        if let open = openNote, notes.contains(where: { $0.url == open }) { return }
        if openNote != notes.first?.url { openNote = notes.first?.url }
    }
    func newNote(_ text: String = "") {
        do { let url = try NotesStore.create(in: notesFolder, text: text); reloadNotes(); openNote = url } catch { notify(error.localizedDescription) }
    }
    /// Saves the note as it is typed. The list keeps its order while you write.
    func saveNote(_ url: URL, text: String) {
        let manager = FileManager.default
        // A note moved to the Trash meanwhile isn't brought back by a save still due.
        guard manager.fileExists(atPath: url.path) else { return }
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        do {
            // Changed in another app since Verb read it, as in Obsidian or on another Mac through iCloud:
            // Verb's version goes beside it rather than over it.
            if let known = notes.first(where: { $0.url == url }), let onDisk = modified(url), onDisk.timeIntervalSince(known.modified) > 1,
               let current = try? String(contentsOf: url, encoding: .utf8), current != known.text, current != text {
                let base = url.deletingPathExtension().lastPathComponent, folder = url.deletingLastPathComponent()
                var copy = folder.appendingPathComponent(base + " (Verb).md"), number = 2
                while manager.fileExists(atPath: copy.path) { copy = folder.appendingPathComponent("\(base) (Verb \(number)).md"); number += 1 }
                try NotesStore.write(text, to: copy)
                notify("This note changed in another app. Your version is saved beside it.")
                reloadNotes(); openNote = copy
                return
            }
            try NotesStore.write(text, to: url)
            if let index = notes.firstIndex(where: { $0.url == url }) { notes[index].text = text; notes[index].modified = modified(url) ?? Date() }
        } catch { notify(error.localizedDescription) }
    }
    /// Moves the note to the Trash, where it can still be taken back.
    func trashNote(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.notify(error.localizedDescription) }
                if self?.openNote == url { self?.openNote = nil }
                self?.reloadNotes()
            }
        }
    }
    func chooseNotesFolder() {
        let panel = NSOpenPanel(); panel.prompt = lang("Use This Folder", "Usa questa cartella"); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = lang("Use this folder", "Usa questa cartella")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.notesPath = url.path
        openNote = nil; reloadNotes()
    }

    // MARK: Meetings

    /// Where meeting recordings are kept, one folder each.
    var meetingsFolder: URL { paths.root.appendingPathComponent("Meetings", isDirectory: true) }

    func startMeeting() {
        guard meeting == .idle else { return }
        guard settings.speechProvider == .onDevice, speechInstalled else { notify("Meeting notes need the speech model on this Mac. Download it in Models."); return }
        let folder = meetingsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: meetingsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            meetingRecorder.onProblem = { [weak self] problem in self?.notify(problem) }
            try meetingRecorder.start(in: folder, microphone: settings.microphoneID, preferBuiltIn: settings.preferBuiltInMic)
            meetingKind = settings.meetingTemplate; meetingNotes = ""
            var journal = MeetingJournal(started: Date()); journal.template = meetingKind
            journal.save(in: folder)
            meetingDictations = []
            meeting = .recording(Date())
            menuChanged?()
            // Recording people is theirs to agree to; and a meeting with the microphone alone says so.
            if let problem = meetingRecorder.systemProblem {
                // Why the others are missing, and how to have them next time.
                hint("Recording your microphone only: the Mac's sound can't be recorded.")
                notify(AppModel.othersMissing + " " + problem)
            } else { hint("Recording the meeting. Let the others know.") }
        } catch { notify(error.localizedDescription) }
    }

    func stopMeeting() {
        guard case .recording = meeting, let recording = meetingRecorder.stop() else { return }
        meetingEnded = nil
        saveMeetingNotes(in: recording.folder)
        closeJournal(recording)
        meeting = .writing(lang("Writing down the meeting…", "Trascrivo la riunione…"))
        menuChanged?()
        Task { await writeMeeting(recording) }
    }

    /// Quitting: a meeting being recorded is closed and written down at the next launch, as one
    /// being written down is.
    func stopMeetingForQuit() {
        guard case .recording = meeting, let recording = meetingRecorder.stop() else { return }
        saveMeetingNotes(in: recording.folder)
        closeJournal(recording)
    }
    /// The recording ended: its length and loudness join what the journal already holds.
    private func closeJournal(_ recording: (folder: URL, started: Date, duration: Double, othersPeak: Float?)) {
        var journal = MeetingJournal.load(from: recording.folder) ?? MeetingJournal(started: recording.started)
        journal.duration = recording.duration; journal.othersPeak = recording.othersPeak
        if journal.template == nil { journal.template = meetingKind }
        journal.save(in: recording.folder)
    }
    /// What you typed during the meeting, kept beside its recordings so a meeting cut short keeps it too.
    func saveMeetingNotes(in folder: URL? = nil) {
        guard let folder = folder ?? meetingRecorder.folder else { return }
        try? Data(meetingNotes.utf8).write(to: folder.appendingPathComponent("notes.md"), options: .atomic)
    }
    /// The kind of notes of the meeting being recorded, changed while it runs.
    func setMeetingKind(_ id: String) {
        meetingKind = id
        guard let folder = meetingRecorder.folder, var journal = MeetingJournal.load(from: folder) else { return }
        journal.template = id; journal.save(in: folder)
    }
    /// The kinds of notes to choose from: Verb's own, then yours.
    func meetingKinds(_ t: Lang) -> [(id: String, name: String)] {
        MeetingTemplate.standard.map { ($0.id, $0.names[t.isItalian ? 1 : 0]) } + settings.customMeetingTemplates.map { ($0.id, $0.name.isEmpty ? t("Untitled", "Senza nome") : $0.name) }
    }
    /// The note as a Word document, saved where you choose.
    func exportNote(_ note: Note) {
        let panel = NSSavePanel(); panel.prompt = lang("Export", "Esporta")
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = (note.title ?? note.url.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "/", with: "-") + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let html = "<meta charset=\"utf-8\"><body style=\"font-family: -apple-system, Helvetica; font-size: 12pt\">" + RichText.html(fromMarkdown: note.body) + "</body>"
            let document = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            let data = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        } catch { notify(error.localizedDescription) }
    }

    /// Meetings that a quit or a crash left unwritten are written down now, one after another,
    /// and those that couldn't be are tried again, three times in all.
    func recoverMeetings() async {
        guard speechInstalled, settings.speechProvider == .onDevice else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsFolder, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            guard meeting == .idle, let journal = MeetingJournal.load(from: folder), !journal.failed || (journal.tries ?? 1) < 3 else { continue }
            await writeDown(folder, journal: journal)
        }
    }
    /// A meeting that couldn't be written down, tried again now.
    func retryMeeting(_ folder: URL) {
        guard meeting == .idle, let journal = MeetingJournal.load(from: folder) else { return }
        guard speechInstalled, settings.speechProvider == .onDevice else { notify("Meeting notes need the speech model on this Mac. Download it in Models."); return }
        Task { await writeDown(folder, journal: journal) }
    }
    /// A meeting that couldn't be written down, and its recordings, gone for good.
    func deleteMeeting(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        reloadFailedMeetings()
    }
    /// The meetings that couldn't be written down, newest first, for Notes to offer.
    func reloadFailedMeetings() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsFolder, includingPropertiesForKeys: nil)) ?? []
        let failed = folders.compactMap { folder in MeetingJournal.load(from: folder).flatMap { $0.failed ? FailedMeeting(folder: folder, started: $0.started) : nil } }.sorted { $0.started > $1.started }
        if failed != failedMeetings { failedMeetings = failed }
    }
    /// Writes down a meeting left in its folder, interrupted or tried before.
    private func writeDown(_ folder: URL, journal: MeetingJournal) async {
            var journal = journal
            let you = folder.appendingPathComponent("you.wav"), others = folder.appendingPathComponent("others.wav")
            // A recording cut short never had its sizes written: put them right first.
            WAVRepair.repair(you); if FileManager.default.fileExists(atPath: others.path) { WAVRepair.repair(others) }
            if journal.duration == nil { journal.duration = (try? AVAudioFile(forReading: you)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
            meeting = .writing(lang("Writing down an interrupted meeting…", "Trascrivo una riunione interrotta…")); menuChanged?()
            // How loud the Mac's sound was isn't known here; a file that exists had something in it.
            await writeMeeting((folder, journal.started, journal.duration ?? 0, journal.othersPeak ?? (FileManager.default.fileExists(atPath: others.path) ? 1 : nil)))
    }

    /// Meeting recordings follow the audio setting: they expire after 14 days, or once written
    /// down when audio isn't kept. A meeting not written down yet, or that couldn't be, stays
    /// until it is, or until you delete it in Notes.
    func pruneMeetings(all: Bool = false) {
        for folder in meetingsToPrune(retention: settings.retention, keepAudio: settings.keepAudio, all: all) { try? FileManager.default.removeItem(at: folder) }
        reloadFailedMeetings()
    }
    /// The meeting recordings a setting would remove now.
    func meetingsToPrune(retention: Retention, keepAudio: Bool, all: Bool = false) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return folders.filter { folder in
            if case .recording = meeting, meetingRecorder.folder == folder { return false }
            let journal = MeetingJournal.load(from: folder)
            if journal != nil && !all { return false }
            let created = journal?.started ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return all || !keepAudio || retention == .none || Date().timeIntervalSince(created) > 14 * 86400
        }
    }

    private func writeMeeting(_ recording: (folder: URL, started: Date, duration: Double, othersPeak: Float?)) async {
        do {
            let othersFile = recording.folder.appendingPathComponent("others.wav"), both = FileManager.default.fileExists(atPath: othersFile.path)
            defer { meetingProgress = nil }
            let you = try await utterances(of: recording.folder.appendingPathComponent("you.wav"), speaker: .you, share: 0..<(both ? 0.5 : 1))
            // The Mac's sound may have given nothing at all: the meeting is written from your side.
            let others = both ? ((try? await utterances(of: othersFile, speaker: .others, share: 0.5..<1)) ?? []) : []
            // What you dictated during the meeting was for another app, not for the meeting.
            let mine = you.filter { line in !meetingDictations.contains { $0.overlaps(line.start...max(line.start, line.end)) } }
            let lines = MeetingNotes.merge(you: mine, others: others)
            // The note is in the language spoken, headings and labels included.
            let recognizer = NLLanguageRecognizer(); recognizer.processString(lines.map(\.text).joined(separator: " "))
            let italian = recognizer.dominantLanguage.map { $0 == .italian } ?? (settings.interfaceOptions.language == .italian)
            let t = Lang(language: italian ? .italian : .english)
            var transcript = lines.isEmpty ? "_" + t("No words were recognized.", "Nessuna parola riconosciuta.") + "_" : MeetingNotes.transcript(lines, you: t("You", "Tu"), others: t("Others", "Altri"))
            if !both {
                transcript = "_" + t("Only your microphone was recorded. To include a call next time, allow Verb in System Settings → Privacy & Security → Screen & System Audio Recording.",
                                     "È stato registrato solo il tuo microfono. Per includere una chiamata la prossima volta, consenti Verb in Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema.") + "_\n\n" + transcript
            } else if (recording.othersPeak ?? 0) < 0.0005 && recording.duration > 20 {
                transcript = "_" + t("Verb heard nothing from the Mac’s sound. If this was a call, allow Verb to record system audio in System Settings → Privacy & Security, then record the next meeting.",
                                     "Verb non ha sentito nulla dall’audio del Mac. Se era una chiamata, consenti a Verb di registrare l’audio di sistema in Impostazioni di Sistema → Privacy e sicurezza, poi registra la prossima riunione.") + "_\n\n" + transcript
            }
            // Notes that couldn't be summed up say why, and how to have them.
            var summary: String?
            let journal = MeetingJournal.load(from: recording.folder)
            let typed = (try? String(contentsOf: recording.folder.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            if settings.cleanupProvider != .off, !lines.isEmpty {
                meeting = .writing(lang("Summing up the meeting…", "Riassumo la riunione…"))
                do { summary = try await summarise(MeetingNotes.transcript(lines, you: t("You", "Tu"), others: t("Others", "Altri")), italian: italian, template: journal?.template ?? MeetingTemplate.general, notes: typed) }
                catch is CancellationError { summary = "_" + t("No summary: the writing model was switched off. The transcript below is complete; run a transform on this note to sum it up.", "Nessun riassunto: il modello di scrittura è stato disattivato. La trascrizione qui sotto è completa: usa una trasformazione su questa nota per riassumerla.") + "_" }
                catch { summary = "_" + t("No summary: \(t.message(error.localizedDescription)) The transcript below is complete; run a transform on this note to sum it up.", "Nessun riassunto: \(t.message(error.localizedDescription)) La trascrizione qui sotto è completa: usa una trasformazione su questa nota per riassumerla.") + "_" }
            } else if !lines.isEmpty {
                summary = "_" + t("No summary, as there is no writing model. Choose one in Models, then run a transform on this note to sum it up.", "Nessun riassunto, perché non c’è un modello di scrittura. Scegline uno in Modelli, poi usa una trasformazione su questa nota per riassumerla.") + "_"
            }
            let when = recording.started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: italian ? "it_IT" : "en_GB")))
            // A kind other than the general one names the note: "Stand-up, 12 ott, 10:30".
            let kind = (journal?.template).flatMap { id in id == MeetingTemplate.general ? nil : MeetingTemplate.standardName(id, italian: italian) ?? settings.customMeetingTemplates.first { $0.id == id }?.name }
            let title = kind.map { "\($0), \(when)" } ?? t("Meeting, \(when)", "Riunione del \(when)")
            let document = MeetingNotes.document(title: title, date: recording.started, minutes: max(1, Int((recording.duration / 60).rounded())),
                                                 summary: summary, transcript: transcript, headings: (t("Notes", "Note"), t("Transcript", "Trascrizione")), notes: (t("Your notes", "I tuoi appunti"), typed))
            let url = try NotesStore.create(in: notesFolder, text: document, suffix: t("Meeting", "Riunione"), now: recording.started)
            // Written down: the recordings stay only if you keep audio, and expire like the others.
            MeetingJournal.remove(from: recording.folder)
            if !settings.keepAudio || settings.retention == .none { try? FileManager.default.removeItem(at: recording.folder) }
            meeting = .idle; menuChanged?(); scheduleIdleUnload()
            reloadNotes(); openNote = url
            status = "The meeting notes are ready."; outcome = .learned
            flashOutcome?()
        } catch {
            // The recordings wait in their folder: Notes offers Retry, and the next launch tries again.
            if var journal = MeetingJournal.load(from: recording.folder) { journal.failed = true; journal.tries = (journal.tries ?? 0) + 1; journal.save(in: recording.folder) }
            meeting = .idle; menuChanged?(); scheduleIdleUnload()
            reloadFailedMeetings()
            notify(AppModel.meetingNotWritten + " " + error.localizedDescription)
        }
    }

    /// Each utterance of one side of the meeting, with its time: the voice-activity detector
    /// finds them, the speech model writes them down, a few minutes of audio at a time.
    /// `share` is the part of the whole meeting's progress this track stands for.
    private func utterances(of url: URL, speaker: Speaker, share: Range<Double> = 0..<1) async throws -> [Utterance] {
        let reader = try SpeechPCMReader(url)
        var read = 0.0
        var activity = VoiceActivity(), buffer: [Float] = [], bufferStart = 0, lines: [Utterance] = []
        let variant = settings.localModel, language = settings.language, vocabulary = library.vocabulary
        func write(_ segment: VoiceActivity.Segment) async throws {
            let from = max(segment.start - bufferStart, 0), to = min(segment.end - bufferStart, buffer.count)
            guard to - from > 16000 / 3 else { return }
            let text = TextRules.quickClean(TextRules.corrected(try await speech.recognize(samples: Array(buffer[from..<to]), variant: variant, language: language), vocabulary: vocabulary), language: language.rawValue)
            if !text.isEmpty { lines.append(Utterance(speaker: speaker, start: Double(segment.start) / 16000, end: Double(segment.end) / 16000, text: text)) }
        }
        repeat {
            try Task.checkCancellation()
            let window = try reader.read(seconds: 60)
            buffer += window
            read += Double(window.count) / 16000
            if reader.duration > 0 { meetingProgress = share.lowerBound + (share.upperBound - share.lowerBound) * min(1, read / reader.duration) }
            var ended: [VoiceActivity.Segment] = []
            for start in stride(from: 0, to: window.count, by: 1600) {
                for event in activity.process(Array(window[start..<min(start + 1600, window.count)])) { if case .ended(let segment) = event { ended.append(segment) } }
            }
            for segment in ended { try await write(segment) }
            // An utterance still open needs at most its last thirty seconds.
            let keep = 16000 * 35
            if buffer.count > keep { let drop = buffer.count - keep; buffer.removeFirst(drop); bufferStart += drop }
        } while !reader.atEnd
        // A second of silence closes the last utterance.
        for event in activity.process([Float](repeating: 0, count: 16000)) { if case .ended(let segment) = event { try await write(segment) } }
        return lines
    }

    /// The meeting's notes from the writing model. A local model reads a long meeting in parts,
    /// then puts their notes together.
    /// Each call reads the settings as they are then, so a writing model switched off, or remote
    /// processing turned off, while the meeting is transcribed is respected.
    private func summarise(_ transcript: String, italian: Bool, template: String = MeetingTemplate.general, notes: String = "") async throws -> String {
        guard settings.cleanupProvider != .off else { throw CancellationError() }
        if settings.cleanupProvider == .local { try await writer.start() }
        let instruction = MeetingNotes.summaryInstruction(template: template, custom: settings.customMeetingTemplates, italian: italian, notes: notes)
        let parts = settings.cleanupProvider == .local ? MeetingNotes.parts(transcript, words: 2500) : [transcript]
        var notes: [String] = []
        for part in parts {
            notes.append(try await client.edit(text: part, style: .natural, vocabulary: library.vocabulary, settings: settings, key: Secrets.read("cleanup"), instruction: instruction, selection: part))
        }
        guard notes.count > 1 else { return notes.first ?? "" }
        let joined = notes.joined(separator: "\n\n")
        let combine = italian ? "Queste sono le note di parti successive della stessa riunione. Uniscile in un’unica nota con le stesse sezioni, senza ripetizioni. Scrivi in italiano."
                              : "These are the notes of successive parts of one meeting. Merge them into one note with the same sections, without repetition. Write in English."
        return try await client.edit(text: joined, style: .natural, vocabulary: library.vocabulary, settings: settings, key: Secrets.read("cleanup"), instruction: combine, selection: joined)
    }
}

/// What a meeting folder holds while its notes are still to be written, so a meeting cut short
/// by a quit or a crash is written down at the next launch. It goes once the notes exist.
struct MeetingJournal: Codable {
    var started: Date
    var duration: Double?
    var othersPeak: Float?
    /// Writing it down failed: Notes offers it again, and its recordings stay until you decide.
    var failed = false
    /// How many times writing it down failed; it is tried again at launch until three.
    var tries: Int?
    /// The kind of notes chosen for it.
    var template: String?
    init(started: Date, duration: Double? = nil, othersPeak: Float? = nil) { self.started = started; self.duration = duration; self.othersPeak = othersPeak }
    private static func url(in folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }
    static func load(from folder: URL) -> MeetingJournal? { (try? Data(contentsOf: url(in: folder))).flatMap { try? JSONDecoder().decode(MeetingJournal.self, from: $0) } }
    func save(in folder: URL) { try? JSONStore.save(self, to: Self.url(in: folder)) }
    static func remove(from folder: URL) { try? FileManager.default.removeItem(at: url(in: folder)) }
}
