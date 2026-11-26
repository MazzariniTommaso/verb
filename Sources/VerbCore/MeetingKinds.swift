import Foundation

/// How a meeting's notes are written: Verb's own kinds of meeting, and any you describe.
public struct MeetingTemplate: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// What the notes should hold, in your words. Empty for Verb's own, which have theirs.
    public var instruction: String
    public init(id: String = UUID().uuidString, name: String, instruction: String) { self.id = id; self.name = name; self.instruction = instruction }

    public static let general = "general"
    /// Verb's own kinds, by id, with their names in English and Italian.
    public static let standard: [(id: String, names: [String])] = [
        (general, ["General", "Generale"]), ("one-on-one", ["One-on-one", "Uno a uno"]), ("standup", ["Stand-up", "Stand-up"]),
        ("client", ["Client or sales call", "Cliente o vendita"]), ("interview", ["Interview", "Colloquio"]), ("lecture", ["Lesson or talk", "Lezione o talk"]),
    ]
    public static func standardName(_ id: String, italian: Bool) -> String? { standard.first { $0.id == id }?.names[italian ? 1 : 0] }
}

extension MeetingNotes {
    /// What the writing model is asked for: the kind's sections, in the meeting's language, and
    /// the notes you typed while it ran, which say what mattered to you.
    public static func summaryInstruction(template id: String, custom: [MeetingTemplate], italian: Bool, notes: String? = nil) -> String {
        var instruction: String
        if let own = custom.first(where: { $0.id == id }), !own.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instruction = (italian ? "Scrivi le note di questa riunione a partire dalla trascrizione, in Markdown, come chiede l’utente: " : "Write the notes of this meeting from the transcript, in Markdown, as the user asks: ")
                + own.instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)
                + (italian ? " Scrivi in italiano. Non aggiungere nulla che non sia nella trascrizione." : " Write in English. Add nothing that is not in the transcript.")
        } else {
            switch id {
            case "one-on-one":
                instruction = italian ? "Scrivi le note di questo incontro uno a uno a partire dalla trascrizione. Usa Markdown con queste sezioni, omettendo quelle vuote: **Aggiornamenti**, **Ostacoli**, **Feedback** (dato e ricevuto), **Crescita e obiettivi**, **Impegni** (chi fa cosa, e quando, se è stato detto). Scrivi in italiano. Non aggiungere nulla che non sia nella trascrizione."
                    : "Write the notes of this one-on-one from the transcript. Use Markdown with these sections, leaving out any that would be empty: **Updates**, **Blockers**, **Feedback** (given and received), **Growth and goals**, **Commitments** (who does what, and when, if said). Write in English. Add nothing that is not in the transcript."
            case "standup":
                instruction = italian ? "Scrivi le note di questo stand-up a partire dalla trascrizione. Per ogni persona che ha parlato: **Fatto**, **Da fare**, **Ostacoli**. Poi **Da seguire** con le azioni concordate. Usa Markdown, frasi brevi, in italiano. Non aggiungere nulla che non sia nella trascrizione."
                    : "Write the notes of this stand-up from the transcript. For each person who spoke: **Done**, **Next**, **Blockers**. Then **Follow-ups** with the agreed actions. Use Markdown, short lines, in English. Add nothing that is not in the transcript."
            case "client":
                instruction = italian ? "Scrivi le note di questa chiamata con un cliente a partire dalla trascrizione. Usa Markdown con queste sezioni, omettendo quelle vuote: **Contesto**, **Esigenze e problemi**, **Obiezioni**, **Budget e tempi**, **Prossimi passi** (chi fa cosa, e quando). Scrivi in italiano. Non aggiungere nulla che non sia nella trascrizione."
                    : "Write the notes of this client call from the transcript. Use Markdown with these sections, leaving out any that would be empty: **Context**, **Needs and pain points**, **Objections**, **Budget and timing**, **Next steps** (who does what, and when). Write in English. Add nothing that is not in the transcript."
            case "interview":
                instruction = italian ? "Scrivi le note di questo colloquio a partire dalla trascrizione. Usa Markdown con queste sezioni, omettendo quelle vuote: **Profilo**, **Esperienze rilevanti**, **Punti di forza**, **Dubbi**, **Domande del candidato**, **Prossimi passi**. Riporta i fatti detti, senza giudizi che non siano nella trascrizione. Scrivi in italiano."
                    : "Write the notes of this interview from the transcript. Use Markdown with these sections, leaving out any that would be empty: **Background**, **Relevant experience**, **Strengths**, **Concerns**, **Candidate’s questions**, **Next steps**. Report what was said, with no judgement that is not in the transcript. Write in English."
            case "lecture":
                instruction = italian ? "Scrivi gli appunti di questa lezione o presentazione a partire dalla trascrizione. Usa Markdown: **Argomenti** con i concetti principali in punti, **Definizioni ed esempi**, **Domande emerse**, **Da approfondire**. Scrivi in italiano. Non aggiungere nulla che non sia nella trascrizione."
                    : "Write study notes of this lesson or talk from the transcript. Use Markdown: **Topics** with the main ideas as points, **Definitions and examples**, **Questions raised**, **To look into**. Write in English. Add nothing that is not in the transcript."
            default:
                instruction = summaryInstruction(italian: italian)
            }
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            instruction += italian ? "\nDurante la riunione l’utente ha preso questi appunti. Indicano ciò che conta per lui: includi i loro punti, chiariti con la trascrizione.\n<<<\n\(notes.prefix(4000))\n>>>"
                                   : "\nDuring the meeting the user took these notes. They show what matters to them: include their points, made clear with the transcript.\n<<<\n\(notes.prefix(4000))\n>>>"
        }
        return instruction
    }
}

/// Notices calls: an app for calls, or a call in a browser tab, that keeps the microphone on.
/// It offers to record once per call, and says when the call recorded has ended, when the app
/// lets the microphone go. Times are seconds; nothing here reads what is said.
public struct MeetingWatch: Sendable {
    public enum Action: Equatable, Sendable {
        /// A call started in this app: record it?
        case offer(app: String)
        /// The call being recorded seems over: stop and write the notes?
        case ended(app: String)
    }
    /// Apps for calls, by bundle identifier, with the name the offer says.
    public static let apps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams", "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord", "net.whatsapp.WhatsApp": "WhatsApp", "com.skype.skype": "Skype",
        "com.electron.zohomeeting": "Zoho Meeting", "com.gotomeeting.GoToMeeting": "GoTo Meeting", "ru.keepcoder.Telegram": "Telegram", "com.apple.TelephonyUtilities": "FaceTime",
    ]
    /// Calls in a browser, by host.
    public static let sites: [(host: String, name: String)] = [("meet.google.com", "Google Meet"), ("zoom.us", "Zoom"), ("teams.microsoft.com", "Microsoft Teams"), ("teams.live.com", "Microsoft Teams"),
                                                               ("whereby.com", "Whereby"), ("meet.jit.si", "Jitsi Meet"), ("app.gather.town", "Gather"), ("discord.com", "Discord")]
    public static func site(host: String) -> String? {
        let host = host.lowercased()
        return sites.first { host == $0.host || host.hasSuffix("." + $0.host) }?.name
    }
    /// The app a helper process belongs to: Chrome's helpers use the microphone for its tabs.
    public static func owner(of bundleID: String, known: Set<String>) -> String? {
        if known.contains(bundleID) { return bundleID }
        return known.first { bundleID.hasPrefix($0 + ".") }
    }

    /// How long a call must keep the microphone before the offer, and how long it must have let
    /// it go before the call counts as ended.
    public static let settle: Double = 4, release: Double = 8
    /// After the app lets the microphone go for this long, a new call there is offered again.
    public static let forget: Double = 45

    private var since: [String: Double] = [:]
    private var gone: [String: Double] = [:]
    private var offered: Set<String> = []
    private var recordedApp: String?
    private var endSaid = false
    public init() {}

    /// The call apps using the microphone now, by name, at `now`, and whether Verb records a
    /// meeting. `recording` names the app whose call is being recorded, if one was offered.
    public mutating func update(calls: Set<String>, now: Double, recording: Bool) -> Action? {
        // Gone long enough: its next call is a new one.
        for (name, at) in gone where now - at >= Self.forget && !(recording && name == recordedApp) { offered.remove(name); gone[name] = nil }
        for name in calls where since[name] == nil { since[name] = now }
        for name in Array(since.keys) where !calls.contains(name) { since[name] = nil; gone[name] = now }
        for name in calls { gone[name] = nil }
        if recording {
            if recordedApp == nil { recordedApp = calls.sorted().first }
            guard let app = recordedApp, !endSaid else { return nil }
            if !calls.contains(app), let at = gone[app], now - at >= Self.release { endSaid = true; return .ended(app: app) }
            return nil
        }
        recordedApp = nil; endSaid = false
        if let (name, _) = since.filter({ now - $0.value >= Self.settle && !offered.contains($0.key) }).min(by: { $0.value < $1.value }) {
            offered.insert(name)
            return .offer(app: name)
        }
        return nil
    }
    /// The meeting recorded is for this app's call.
    public mutating func recording(_ app: String) { recordedApp = app; endSaid = false; offered.insert(app) }
}
