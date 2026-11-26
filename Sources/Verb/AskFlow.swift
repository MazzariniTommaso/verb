import AppKit
import VerbCore
import VerbEngine

// The command keys with nothing selected: a request. A few are actions Verb does on this Mac
// without a model (open an app or a site, find files, search the web, add a word to the
// dictionary, remember something, take a note, record a meeting); the rest go to the writing
// model, which writes the text asked for where the cursor is, or answers in a card.

extension AppModel {
    func ask(_ request: String, record: inout DictationRecord, target: TextTarget?, settings snapshot: Settings, library words: Library, started: Date) async throws {
        record.mode = .ask; record.rawText = request
        rewrite = .ask
        func done(_ text: String, delivery: String, outcome result: Outcome, status message: String) throws {
            record.text = text; record.status = .completed; record.delivery = delivery; record.processingSeconds = Date().timeIntervalSince(started)
            status = message; outcome = result
            try keepAsk(&record, settings: snapshot)
        }
        // The ask keys take questions only: no action, nothing written into the field.
        switch askingOnly ? AskIntent.ask(request) : Assistant.intent(of: request) {
        case .addWord(let word):
            var updated = library
            let added = LibraryTransfer.merge([VocabularyEntry(word: word)], into: &updated.vocabulary, snippets: updated.snippets).added
            if added > 0 { library = updated }
            try done(word, delivery: "Added to the dictionary", outcome: .learned, status: added > 0 ? "“\(word)” is in the dictionary." : "“\(word)” was already in the dictionary.")
            return
        case .remember(let fact):
            let before = settings.personalInstructions
            settings.personalInstructions = before.isEmpty ? fact : before + "\n" + fact
            try done(fact, delivery: "Kept in your instructions", outcome: .learned, status: "Verb will remember it. It’s in Settings → Styles.")
            return
        case .openApp(let name):
            if let url = AppFinder.find(name) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                let app = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                try done(app, delivery: "Opened \(app)", outcome: .delivered, status: "Opened \(app)")
                return
            }
            if let site = Places.sites.first(where: { TextRules.canonical($0.name).lowercased() == TextRules.canonical(name).lowercased() }), let host = site.hosts.first, let url = URL(string: "https://" + host) {
                NSWorkspace.shared.open(url)
                try done(site.name, delivery: "Opened \(site.name)", outcome: .delivered, status: "Opened \(site.name)")
                return
            }
            // No app by that name: a request after all.
        case .openSite(let url):
            NSWorkspace.shared.open(url)
            let host = url.host ?? url.absoluteString
            try done(host, delivery: "Opened \(host)", outcome: .delivered, status: "Opened \(host)")
            return
        case .webSearch(let query):
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = components?.url { NSWorkspace.shared.open(url) }
            try done(query, delivery: "Searched the web", outcome: .delivered, status: "Searching the web for “\(query)”")
            return
        case .findFiles(let query):
            setPhase(.polishing)
            let files = await FileSearch.find(query)
            answerTarget = nil
            showAnswer(AnswerCard(request: request, files: files, problem: files.isEmpty ? "No file matches “\(query)”." : nil))
            try done(files.map(\.lastPathComponent).joined(separator: "\n"), delivery: files.isEmpty ? "No files found" : "Files found", outcome: files.isEmpty ? .hint : .delivered,
                     status: files.isEmpty ? "No file matches “\(query)”." : "Files found: \(files.count)")
            return
        case .newNote:
            toggleNotepad?(); newNote()
            try done(request, delivery: "New note", outcome: .delivered, status: "New note")
            return
        case .startMeeting:
            startMeeting()
            try done(request, delivery: "Meeting recording", outcome: .delivered, status: "Recording the meeting")
            return
        case .stopMeeting:
            stopMeeting()
            try done(request, delivery: "Meeting stopped", outcome: .delivered, status: "Writing the meeting notes")
            return
        case .ask: break
        }
        try await answerWithModel(request, record: &record, target: target, settings: snapshot, library: words, started: started)
    }

    /// A question or a text to write, for the writing model. A text to write goes where the
    /// cursor is, as a dictation does; an answer appears in the card as it comes.
    private func answerWithModel(_ request: String, record: inout DictationRecord, target: TextTarget?, settings snapshot: Settings, library words: Library, started: Date) async throws {
        guard snapshot.cleanupProvider != .off else { record.status = .failed; try? discard(record); status = "Choose a writing model in Models to ask Verb."; outcome = .hint; return }
        let site = sessionSite
        let field = target.map { $0.verdict != .none && !$0.secure } ?? false
        let draft = !askingOnly && Assistant.isDraft(request) && field && snapshot.autoInsert
        // What is on screen stays on this Mac: only a model on this Mac reads it.
        let local = snapshot.writingStaysOnMac
        let near = local ? target.flatMap { FieldContext.nearbyText($0) } : nil
        let screen = local && snapshot.askReadsScreen ? target.flatMap { ScreenText.read(pid: $0.pid) } : nil
        let choice = snapshot.styleChoice(for: record.bundleID, site: site)
        let style = choice.style == .custom ? snapshot.stylePrompt(for: record.bundleID, site: site) : choice.style == .verbatim ? nil : choice.style.detail
        let place = target.map { site?.name ?? $0.appName }
        // A question asked with the box still open follows on from the ones before it.
        let earlier = askingOnly ? conversation : []
        let system = Assistant.systemPrompt(personal: snapshot.personalInstructions, place: draft ? place : nil, style: draft ? style : nil, hasContext: near != nil || screen != nil, conversation: !earlier.isEmpty)
        let user = Assistant.userMessage(request: request, near: near, screen: screen, earlier: earlier)
        setPhase(.polishing)
        if snapshot.cleanupProvider == .local { try await writer.start() }
        if draft, let target {
            let text = try await client.ask(system: system, user: user, settings: snapshot, key: Secrets.read("cleanup"))
            try Task.checkCancellation()
            let shaped = choice.style == .lowercase ? TextRules.chatCase(text, keep: Set(words.vocabulary.map(\.word)).union(AppModel.properNames(in: text))) : text
            let paste = pasteForm(shaped, bundleID: target.bundleID, site: site, settings: snapshot)
            latestText = paste.text; latestOriginal = request
            setPhase(.inserting)
            record.delivery = try await inserter.insert(paste.text, html: paste.html, target: target, late: { [weak self] in self?.status = "Paste sent to \(target.appName)" })
            record.text = paste.text; record.status = .completed; record.processingSeconds = Date().timeIntervalSince(started)
            status = record.delivery; outcome = Outcome.of(delivery: record.delivery)
            try keepAsk(&record, settings: snapshot)
            if snapshot.soundFeedback, outcome == .delivered { NSSound(named: "Pop")?.play() }
            return
        }
        answerTarget = field ? target : nil
        showAnswer(AnswerCard(request: request, streaming: true, canInsert: field))
        let card = answer?.id
        let text = try await client.ask(system: system, user: user, settings: snapshot, key: Secrets.read("cleanup"), partial: { [weak self] so in
            Task { @MainActor in if let self, self.answer?.id == card { self.answer?.text = so } }
        })
        try Task.checkCancellation()
        if answer?.id == card { answer?.text = text; answer?.streaming = false; answerArmed = true }
        if askingOnly { conversation.append(Assistant.Turn(question: request, answer: text)) }
        latestText = text; latestOriginal = request
        record.text = text; record.status = .completed; record.delivery = "Answered"; record.processingSeconds = Date().timeIntervalSince(started)
        status = "Answered"; outcome = .delivered
        try keepAsk(&record, settings: snapshot)
    }

    /// A request is kept in History like a voice edit, without its recording when audio isn't kept.
    private func keepAsk(_ record: inout DictationRecord, settings snapshot: Settings) throws {
        if snapshot.retention == .none || !snapshot.keepAudio, let name = record.audioName, let url = paths.audioURL(name) { try? FileManager.default.removeItem(at: url); record.audioName = nil }
        if snapshot.retention != .none { try store.save(record) }
        reloadHistory()
    }

    /// Text with Markdown as the app takes it: formatted where formatting is kept, as plain words
    /// in a chat, as written in an editor. The HTML is for apps that read it.
    func pasteForm(_ text: String, bundleID: String, site: Site?, settings snapshot: Settings) -> (text: String, html: String?) {
        guard snapshot.formatForApp, RichText.hasFormatting(text) else { return (text, nil) }
        switch PasteFormat.choose(bundleID: bundleID, site: site, code: CodeApps.isCode(bundleID)) {
        case .raw: return (text, nil)
        case .plain: return (RichText.plain(fromMarkdown: text), nil)
        case .rich: return (RichText.plain(fromMarkdown: text), RichText.html(fromMarkdown: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    // MARK: The card

    func showAnswer(_ card: AnswerCard) {
        answerTask?.cancel()
        answer = card; answerArmed = !card.streaming
        flashOutcome?()
    }
    /// Return in the card: the answer goes where the request was made, or, with no field, on the clipboard.
    func useAnswer() {
        guard let card = answer, !card.streaming else { return }
        if let first = card.files.first { NSWorkspace.shared.open(first); closeAnswer(); return }
        guard !card.text.isEmpty else { closeAnswer(); return }
        guard card.canInsert, let target = answerTarget else { copyAnswer(); return }
        let paste = pasteForm(card.text, bundleID: target.bundleID, site: SiteReader.site(of: target), settings: settings)
        closeAnswer()
        guard !busy else { return }
        setPhase(.inserting)
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.setPhase(.idle) }
            do { self.status = try await self.inserter.insert(paste.text, html: paste.html, target: target); self.outcome = Outcome.of(delivery: self.status) }
            catch { if !Task.isCancelled { self.notify(error.localizedDescription); self.status = "Couldn't paste"; self.outcome = .failed } }
        }
    }
    func copyAnswer() {
        guard let card = answer else { return }
        copy(card.files.isEmpty ? RichText.plain(fromMarkdown: card.text) : card.files.map(\.path).joined(separator: "\n")); outcome = .copied
        closeAnswer(); flashOutcome?()
    }
    func closeAnswer() { answer = nil; answerTarget = nil; answerArmed = false; conversation = []; askingOnly = false; flashOutcome?() }

    // MARK: Calls

    /// Every few seconds while meeting detection is on: the apps on a call are checked, and a call
    /// that starts or ends is said in the overlay.
    func watchMeetings() {
        meetingWatchTimer?.invalidate(); meetingWatchTimer = nil
        guard runsServices, settings.meetingDetection else { meetingOffer = nil; return }
        meetingWatchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkCalls() } }
    }
    private func checkCalls() {
        let known = Set(MeetingWatch.apps.keys).union(Places.browsers)
        var calls = Set<String>()
        for user in MicrophoneUsers.now() {
            guard let app = MeetingWatch.owner(of: user.bundleID, known: known) else { continue }
            if let name = MeetingWatch.apps[app] { calls.insert(name); continue }
            // A browser: only a tab on a site for calls, as the browser's own window shows it.
            guard let browser = NSRunningApplication.runningApplications(withBundleIdentifier: app).first,
                  let host = SiteReader.pageURL(inWindowOf: browser.processIdentifier)?.host, let name = MeetingWatch.site(host: host) else { continue }
            calls.insert(name)
        }
        let recording: Bool = { if case .recording = meeting { return true }; return false }()
        switch meetingWatch.update(calls: calls, now: Date().timeIntervalSinceReferenceDate, recording: recording) {
        case .offer(let app)?:
            guard meeting == .idle else { return }
            meetingOffer = app; flashOutcome?()
        case .ended(let app)?: meetingEnded = app; flashOutcome?()
        case nil: if meetingOffer != nil, !calls.contains(meetingOffer ?? "") { meetingOffer = nil; flashOutcome?() }
        }
    }
    func acceptMeetingOffer() {
        guard let app = meetingOffer else { return }
        meetingOffer = nil
        meetingWatch.recording(app)
        startMeeting()
    }
    func declineMeetingOffer() { meetingOffer = nil; flashOutcome?() }
    func endCall() { meetingEnded = nil; stopMeeting() }
    func keepCall() { meetingEnded = nil; flashOutcome?() }

    // MARK: Hints of the first days

    /// Modifiers held alone and let go: the dictation keys may have been meant.
    func lonePress(_ modifiers: KeyModifiers, held: Double) {
        guard !busy, let dictation = settings.keyOptions.dictation, dictation.isModifierOnly else { return }
        var coaching = settings.coachingState
        guard coaching.lonePress(modifiers, held: held, dictation: dictation.modifiers, recent: &lonePresses, now: Date()) else { return }
        settings.coachingState = coaching
        hint("To dictate, hold \(dictation.label).")
    }
    /// A microphone took this long to open: slow ones are said, once a week.
    func microphoneOpened(id: String, name: String, seconds: Double) {
        var coaching = settings.coachingState
        guard coaching.microphoneOpened(id, seconds: seconds, history: &microphoneOpenings, now: Date()) else { return }
        settings.coachingState = coaching
        let shown = String(format: "%.1f", seconds)
        notify("\(name.isEmpty ? "The microphone" : name) takes \(shown) s to start, so your first words can be lost. Wait for the start sound, or test the microphones in Settings → Audio.")
    }
    /// Typing a long text by hand in the first days: a reminder that speaking is quicker.
    func typedLong(_ count: Int) {
        guard !busy, answer == nil, let keys = settings.keyOptions.dictation else { return }
        var coaching = settings.coachingState
        guard coaching.nudge(typed: count, lastDictation: history.first(where: { $0.mode == .dictation })?.createdAt, now: Date()) else { return }
        settings.coachingState = coaching
        hint("Quicker by voice: hold \(keys.label) and say it.")
    }
}
