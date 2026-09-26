import AppKit
import AVFoundation
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
}
extension NoteEditing { var isPractice: Bool { false } }

extension AppModel {
    /// Where the notes are kept: the folder chosen in Settings, or Verb's own.
    var notesFolder: URL { settings.notesPath.isEmpty ? paths.root.appendingPathComponent("Notes", isDirectory: true) : URL(fileURLWithPath: settings.notesPath, isDirectory: true) }
    /// The editor is in front and has the cursor: what Verb writes goes there.
    var writesIntoNote: Bool { NSApp.isActive && noteEditor?.isEditing == true }

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
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
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
            try meetingRecorder.start(in: folder, microphone: Microphones.effective(settings.microphoneID, preferBuiltIn: settings.preferBuiltInMic)?.deviceID)
            MeetingJournal(started: Date()).save(in: folder)
            meetingDictations = []
            meeting = .recording(Date())
            menuChanged?()
            // Recording people is theirs to agree to; and a meeting with the microphone alone says so.
            hint(meetingRecorder.systemProblem == nil ? "Recording the meeting. Let the others know." : "Recording your microphone only: the Mac's sound can't be recorded.")
        } catch { notify(error.localizedDescription) }
    }

    func stopMeeting() {
        guard case .recording = meeting, let recording = meetingRecorder.stop() else { return }
        MeetingJournal(started: recording.started, duration: recording.duration, othersPeak: recording.othersPeak).save(in: recording.folder)
        meeting = .writing(lang("Writing down the meeting…", "Trascrivo la riunione…"))
        menuChanged?()
        Task { await writeMeeting(recording) }
    }

    /// Quitting: a meeting being recorded is closed and written down at the next launch, as one
    /// being written down is.
    func stopMeetingForQuit() {
        guard case .recording = meeting, let recording = meetingRecorder.stop() else { return }
        MeetingJournal(started: recording.started, duration: recording.duration, othersPeak: recording.othersPeak).save(in: recording.folder)
    }

    /// Meetings that a quit or a crash left unwritten are written down now, one after another.
    func recoverMeetings() async {
        guard speechInstalled, settings.speechProvider == .onDevice else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsFolder, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            guard meeting == .idle, var journal = MeetingJournal.load(from: folder), !journal.failed else { continue }
            let you = folder.appendingPathComponent("you.wav"), others = folder.appendingPathComponent("others.wav")
            // A recording cut short never had its sizes written: put them right first.
            WAVRepair.repair(you); if FileManager.default.fileExists(atPath: others.path) { WAVRepair.repair(others) }
            if journal.duration == nil { journal.duration = (try? AVAudioFile(forReading: you)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
            meeting = .writing(lang("Writing down an interrupted meeting…", "Trascrivo una riunione interrotta…")); menuChanged?()
            // How loud the Mac's sound was isn't known here; a file that exists had something in it.
            await writeMeeting((folder, journal.started, journal.duration ?? 0, journal.othersPeak ?? (FileManager.default.fileExists(atPath: others.path) ? 1 : nil)))
        }
    }

    /// Meeting recordings follow the audio setting: they expire after 14 days, or once written
    /// down when audio isn't kept. A meeting still to be written down stays.
    func pruneMeetings(all: Bool = false) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            if case .recording = meeting, meetingRecorder.folder == folder { continue }
            let journal = MeetingJournal.load(from: folder), unwritten = journal.map { !$0.failed } ?? false
            if unwritten && !all { continue }
            let created = journal?.started ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if all || !settings.keepAudio || settings.retention == .none || Date().timeIntervalSince(created) > 14 * 86400 { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private func writeMeeting(_ recording: (folder: URL, started: Date, duration: Double, othersPeak: Float?)) async {
        do {
            let you = try await utterances(of: recording.folder.appendingPathComponent("you.wav"), speaker: .you)
            let othersFile = recording.folder.appendingPathComponent("others.wav")
            // The Mac's sound may have given nothing at all: the meeting is written from your side.
            let others = FileManager.default.fileExists(atPath: othersFile.path) ? ((try? await utterances(of: othersFile, speaker: .others)) ?? []) : []
            // What you dictated during the meeting was for another app, not for the meeting.
            let mine = you.filter { line in !meetingDictations.contains { $0.overlaps(line.start...max(line.start, line.end)) } }
            let lines = MeetingNotes.merge(you: mine, others: others)
            // The note is in the language spoken, headings and labels included.
            let recognizer = NLLanguageRecognizer(); recognizer.processString(lines.map(\.text).joined(separator: " "))
            let italian = recognizer.dominantLanguage.map { $0 == .italian } ?? (settings.interfaceOptions.language == .italian)
            let t = Lang(language: italian ? .italian : .english)
            var transcript = lines.isEmpty ? "_" + t("No words were recognized.", "Nessuna parola riconosciuta.") + "_" : MeetingNotes.transcript(lines, you: t("You", "Tu"), others: t("Others", "Altri"))
            if (recording.othersPeak ?? 0) < 0.0005 && recording.duration > 20 {
                transcript = "_" + t("Verb heard nothing from the Mac’s sound. If this was a call, allow Verb to record system audio in System Settings → Privacy & Security, then record the next meeting.",
                                     "Verb non ha sentito nulla dall’audio del Mac. Se era una chiamata, consenti a Verb di registrare l’audio di sistema in Impostazioni di Sistema → Privacy e sicurezza, poi registra la prossima riunione.") + "_\n\n" + transcript
            }
            var summary: String?
            if settings.cleanupProvider != .off, !lines.isEmpty {
                meeting = .writing(lang("Summing up the meeting…", "Riassumo la riunione…"))
                summary = try? await summarise(MeetingNotes.transcript(lines, you: t("You", "Tu"), others: t("Others", "Altri")), italian: italian)
            }
            let when = recording.started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: italian ? "it_IT" : "en_GB")))
            let document = MeetingNotes.document(title: t("Meeting, \(when)", "Riunione del \(when)"), date: recording.started, minutes: max(1, Int((recording.duration / 60).rounded())),
                                                 summary: summary, transcript: transcript, headings: (t("Notes", "Note"), t("Transcript", "Trascrizione")))
            let url = try NotesStore.create(in: notesFolder, text: document, suffix: t("Meeting", "Riunione"), now: recording.started)
            // Written down: the recordings stay only if you keep audio, and expire like the others.
            MeetingJournal.remove(from: recording.folder)
            if !settings.keepAudio || settings.retention == .none { try? FileManager.default.removeItem(at: recording.folder) }
            meeting = .idle; menuChanged?()
            reloadNotes(); openNote = url
            status = "The meeting notes are ready."; outcome = .learned
            flashOutcome?()
        } catch {
            // Tried once: the recordings wait in their folder and expire like the others.
            if var journal = MeetingJournal.load(from: recording.folder) { journal.failed = true; journal.save(in: recording.folder) }
            meeting = .idle; menuChanged?()
            notify(error.localizedDescription)
        }
    }

    /// Each utterance of one side of the meeting, with its time: the voice-activity detector
    /// finds them, the speech model writes them down, a few minutes of audio at a time.
    private func utterances(of url: URL, speaker: Speaker) async throws -> [Utterance] {
        let reader = try SpeechPCMReader(url)
        var activity = VoiceActivity(), buffer: [Float] = [], bufferStart = 0, lines: [Utterance] = []
        let variant = settings.localModel, language = settings.language, vocabulary = library.vocabulary
        func write(_ segment: VoiceActivity.Segment) async throws {
            let from = max(segment.start - bufferStart, 0), to = min(segment.end - bufferStart, buffer.count)
            guard to - from > 16000 / 3 else { return }
            let text = TextRules.quickClean(TextRules.corrected(try await speech.recognize(samples: Array(buffer[from..<to]), variant: variant, language: language), vocabulary: vocabulary))
            if !text.isEmpty { lines.append(Utterance(speaker: speaker, start: Double(segment.start) / 16000, end: Double(segment.end) / 16000, text: text)) }
        }
        repeat {
            try Task.checkCancellation()
            let window = try reader.read(seconds: 60)
            buffer += window
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
    private func summarise(_ transcript: String, italian: Bool) async throws -> String {
        guard settings.cleanupProvider != .off else { throw CancellationError() }
        if settings.cleanupProvider == .local { try await writer.start() }
        let instruction = MeetingNotes.summaryInstruction(italian: italian)
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
    /// Writing it down failed once: it isn't tried again, and its recordings expire.
    var failed = false
    init(started: Date, duration: Double? = nil, othersPeak: Float? = nil) { self.started = started; self.duration = duration; self.othersPeak = othersPeak }
    private static func url(in folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }
    static func load(from folder: URL) -> MeetingJournal? { (try? Data(contentsOf: url(in: folder))).flatMap { try? JSONDecoder().decode(MeetingJournal.self, from: $0) } }
    func save(in folder: URL) { try? JSONStore.save(self, to: Self.url(in: folder)) }
    static func remove(from folder: URL) { try? FileManager.default.removeItem(at: url(in: folder)) }
}
