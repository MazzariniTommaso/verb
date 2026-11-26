import AppKit
import VerbCore

// The first dictation in an app, with Verb beside you. Chosen at the end of the welcome, the app
// opens and the overlay says what to do: click where you write, then hold the keys and speak.
// It ends when the words go in, after three minutes, or when you close it.

extension AppModel {
    /// Apps to try the first dictation in, those on this Mac, in this order.
    var coachApps: [(name: String, bundleID: String)] {
        ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Notes", "ru.keepcoder.Telegram"].compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""), id) }
        }
    }

    func startCoach(_ bundleID: String) {
        guard runsServices, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        coach = .click(app: name, bundleID: bundleID)
        flashOutcome?()
        coachTask?.cancel()
        coachTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < 180 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let step = self.coach else { return }
                switch step {
                case .click(let app, let id):
                    // In a field of that app: now the keys.
                    if let target = TextTarget.capture(), target.bundleID == id, target.verdict != .none { self.coach = .speak(app: app, bundleID: id); self.flashOutcome?() }
                case .speak: break
                case .done: return
                }
            }
            guard !Task.isCancelled else { return }
            self?.endCoach()
        }
    }

    /// A dictation went into an app: if it is the one being tried, that is the first message done.
    func coachDelivered(bundleID: String) {
        guard let step = coach else { return }
        switch step {
        case .click(let app, let id), .speak(let app, let id):
            guard id == bundleID else { return }
            coach = .done(app: app)
            settings.coachingState.firstMessage = true
            flashOutcome?()
            coachTask?.cancel()
            coachTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, case .done = self.coach else { return }
                self.coach = nil; self.flashOutcome?()
            }
        case .done: break
        }
    }

    func endCoach() { coachTask?.cancel(); coachTask = nil; coach = nil; flashOutcome?() }

    /// Something waits in the overlay for an answer, or the notch style keeps its drop: it stays.
    var overlayHeld: Bool { coach != nil || meetingOffer != nil || meetingEnded != nil || answer != nil || pasteBox != nil }
    var keepsDrop: Bool { settings.overlayStyle == .notch && settings.notchAtRest }
}
