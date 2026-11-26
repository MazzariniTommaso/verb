import Foundation

/// What is going on, as the overlay needs to know it, in plain values.
public struct OverlayFacts: Equatable, Sendable {
    public enum Activity: Equatable, Sendable { case idle, recording, working }
    public enum Mode: Equatable, Sendable { case dictation, edit, ask }
    /// How the last dictation or action ended, while the overlay still says so.
    public enum Ending: Equatable, Sendable { case none, delivered, asSaid, copied, pasted, notPasted, failed, cancelled, empty, hint, learned }
    public enum Prompt: Equatable, Sendable { case meetingOffer, callEnded, coach, suggestion }
    public enum Meeting: Equatable, Sendable { case idle, recording, writing }

    public var activity: Activity = .idle
    public var mode: Mode = .dictation
    /// The writing model rewrites a selection: a voice edit or a transform.
    public var rewriting = false
    /// Words of the live preview to show while you speak.
    public var words = false
    /// Seconds left before a hands-free dictation ends on silence.
    public var silenceLeft: Int?
    /// A long recording waits for a second Escape.
    public var armedCancel = false
    /// The keys went down while the last dictation was still being written.
    public var waitBusy = false
    public var ending: Ending = .none
    /// A cancelled dictation can still be written down.
    public var restorable = false
    public var prompt: Prompt?
    /// An answer, a search's files or a question being asked, in the box.
    public var answer = false
    /// A dictation that found no field waits in the box.
    public var paste = false
    public var pasteCopied = false
    public var meeting: Meeting = .idle
    /// The pointer is over the overlay.
    public var hovering = false
    /// A message's words are still on: they show for a few seconds, then only its symbol.
    public var messageFresh = true

    public init() {}
}

/// What the overlay shows in every style. Beside the notch, or on the closed capsule, only
/// symbols, numbers and keys: `lead` says what is happening, `trail` how much or how. Words
/// appear only when the overlay opens, as `body`.
public struct OverlayScene: Equatable, Sendable {
    public enum Lead: Equatable, Sendable {
        case mark, recording, editing, asking, working, rewriting
        case done(asSaid: Bool), copied, pasted, noSpeech, cancelled, failed, hint, learned
        case meeting, writingNotes, call, callEnded, coach, dictionary, paste, answer
    }
    public enum Trail: Equatable, Sendable {
        case none
        /// The dictation key, to say how to start.
        case key
        /// The recording's time and the stop button.
        case stop
        /// The meeting's time.
        case time
        /// The seconds before a hands-free dictation ends, and the stop button.
        case countdown(Int)
        case close
        /// The box's text was copied.
        case copied
    }
    public enum Body: Equatable, Sendable {
        case none
        /// What you are saying, as it is heard; with `edit`, an instruction for the selection.
        case words(edit: Bool)
        /// The live words, and that the dictation is about to end on silence.
        case silence
        /// One sentence, for a few seconds.
        case message
        /// A sentence with its buttons: Restore, Show why, Record, Stop, Add.
        case choice
        /// The box with a dictation that found no field.
        case paste
        /// The box with a question and its answer.
        case answer
        /// What the symbol means, with its button, while the pointer is over it.
        case detail
    }

    public var lead: Lead?
    public var trail: Trail = .none
    public var body: Body = .none

    public init(lead: Lead? = nil, trail: Trail = .none, body: Body = .none) { self.lead = lead; self.trail = trail; self.body = body }

    /// Nothing to show: the overlay hides, or under a notch only the notch remains.
    public var isEmpty: Bool { lead == nil && body == .none }
    /// Open, with words below the notch or above the capsule's row.
    public var isOpen: Bool { body != .none }

    public static func of(_ facts: OverlayFacts) -> OverlayScene {
        switch facts.activity {
        case .recording:
            let lead: Lead = facts.mode == .edit ? .editing : .recording
            // A question opens the box at once, and the words are written there as you speak.
            if facts.mode == .ask { return OverlayScene(lead: .recording, trail: .stop, body: .answer) }
            if facts.armedCancel { return OverlayScene(lead: lead, trail: .stop, body: .message) }
            if let left = facts.silenceLeft { return OverlayScene(lead: lead, trail: .countdown(left), body: .silence) }
            if facts.words { return OverlayScene(lead: lead, trail: .stop, body: .words(edit: facts.mode == .edit)) }
            return OverlayScene(lead: lead, trail: .stop)
        case .working:
            if facts.answer { return OverlayScene(lead: .working, trail: .close, body: .answer) }
            if facts.waitBusy { return OverlayScene(lead: .working, body: .message) }
            return OverlayScene(lead: facts.rewriting ? .rewriting : .working, body: facts.hovering ? .detail : .none)
        case .idle:
            break
        }
        if facts.answer { return OverlayScene(lead: .answer, trail: .close, body: .answer) }
        if facts.paste { return OverlayScene(lead: .paste, trail: facts.pasteCopied ? .copied : .close, body: .paste) }
        if let prompt = facts.prompt {
            let lead: Lead = switch prompt { case .meetingOffer: .call; case .callEnded: .callEnded; case .coach: .coach; case .suggestion: .dictionary }
            return OverlayScene(lead: lead, trail: .close, body: .choice)
        }
        // A message says its sentence for a few seconds, then keeps only its symbol.
        func message(_ lead: Lead) -> OverlayScene { OverlayScene(lead: lead, body: facts.messageFresh ? .message : .none) }
        switch facts.ending {
        case .failed: return OverlayScene(lead: .failed, trail: .close, body: .choice)
        case .cancelled: return facts.restorable ? OverlayScene(lead: .cancelled, trail: .close, body: .choice) : OverlayScene(lead: .cancelled)
        case .empty: return message(.noSpeech)
        case .hint: return message(.hint)
        case .learned: return message(.learned)
        case .asSaid: return message(.done(asSaid: true))
        case .delivered: return OverlayScene(lead: .done(asSaid: false))
        case .copied: return OverlayScene(lead: .copied)
        case .pasted: return OverlayScene(lead: .pasted)
        // Not pasted, and nothing waiting in the box: as copied, the text is the last dictation.
        case .notPasted: return OverlayScene(lead: .copied)
        case .none: break
        }
        switch facts.meeting {
        case .recording: return OverlayScene(lead: .meeting, trail: .time, body: facts.hovering ? .detail : .none)
        case .writing: return OverlayScene(lead: .writingNotes, body: facts.hovering ? .detail : .none)
        case .idle: break
        }
        return facts.hovering ? OverlayScene(lead: .mark, trail: .key) : OverlayScene()
    }
}

/// The voice as four dots that stretch into capsules, from the level of this moment only: no
/// history, so they follow the voice without waiting.
public enum VoiceDots {
    public static let count = 4
    /// How much each dot takes of the level, the middle ones most.
    static let weights = [0.7, 1, 0.85, 0.6]
    /// Each dot's height, from `low` when silent to `high` at full voice. `time` adds a small
    /// sway of its own to each, so a steady voice still looks alive.
    public static func heights(level: Double, time: Double, low: Double = 5, high: Double = 18) -> [Double] {
        let level = min(1, max(0, level))
        return weights.enumerated().map { index, weight in
            let sway = 0.82 + 0.18 * sin(time * (8 + Double(index) * 3.1) + Double(index) * 2)
            return low + (high - low) * min(1, level * weight * sway * 1.2)
        }
    }
}

/// The room beside the notch in the menu bar, so the overlay never covers the menus of the app
/// in front: they grow from the left edge towards the notch.
public enum MenuRoom {
    /// The free width between the last menu and the notch, `margin` kept from the menu. Menus
    /// are given by their right edges, from the screen's left edge.
    public static func free(menuEnds: [Double], notchLeft: Double, margin: Double = 8) -> Double {
        let last = menuEnds.filter { $0 <= notchLeft }.max() ?? 0
        return max(0, notchLeft - last - margin)
    }
    /// Whether the symbol for the left side fits there; when it doesn't, it goes first on the
    /// right, where the menu bar is almost always free. With no measure, it fits.
    public static func leftFits(_ width: Double, free: Double?) -> Bool { free.map { width <= $0 } ?? true }
}

extension IslandGeometry {
    /// Near the top of a screen without a notch, where the island would be: the pointer within
    /// `radius` of the middle of the top edge. Points from the screen's bottom left.
    public static func near(pointer: CGPoint, screen: CGRect, radius: CGFloat) -> Bool {
        hypot(pointer.x - screen.midX, pointer.y - screen.maxY) <= radius
    }
}
