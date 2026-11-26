import AppKit
import SwiftUI
import VerbCore

// The overlay's pieces, the same in every style: the symbol for what is happening, what goes
// beside it (a time, a key, a control), and what it says once it opens. The notch draws them on
// black; the capsules at the bottom on the overlay's own surface.

extension AppModel {
    /// What is going on, as the overlay reads it. `hovering` is the pointer over the overlay;
    /// `fresh`, a message still in its first seconds.
    func overlayFacts(hovering: Bool, fresh: Bool) -> OverlayFacts {
        var facts = OverlayFacts()
        switch phase {
        case .idle: facts.activity = .idle
        case .authorizing, .recording: facts.activity = .recording
        default: facts.activity = .working
        }
        facts.mode = activeMode == .command ? .edit : askingOnly || activeMode == .ask ? .ask : .dictation
        if case .transform = rewrite { facts.rewriting = true } else if rewrite == .voiceEdit { facts.rewriting = true }
        let words = livePreview
        facts.words = settings.livePreview && phase == .recording && !(words.settled.isEmpty && words.tentative.isEmpty)
        facts.silenceLeft = phase == .recording ? silenceLeft : nil
        facts.armedCancel = cancelArmed && phase == .recording
        facts.waitBusy = pressedWhileBusy
        switch outcome {
        case .none: facts.ending = .none
        case .delivered: facts.ending = asSaid ? .asSaid : pastedLast ? .pasted : .delivered
        case .copied: facts.ending = .copied
        case .copyOnly: facts.ending = .notPasted
        case .failed: facts.ending = .failed
        case .cancelled: facts.ending = .cancelled
        case .empty: facts.ending = .empty
        case .hint: facts.ending = .hint
        case .learned: facts.ending = .learned
        }
        // Once the island has gone back to rest, how the last dictation ended has been said.
        if overlayResting, phase == .idle { facts.ending = .none }
        facts.restorable = canRestore
        if phase == .idle {
            facts.prompt = meetingOffer != nil ? .meetingOffer : meetingEnded != nil ? .callEnded : coach != nil ? .coach : pendingSuggestion != nil ? .suggestion : nil
        }
        facts.answer = answer != nil || ((askingOnly || activeMode == .ask) && phase != .idle)
        facts.paste = pasteBox != nil
        facts.pasteCopied = pasteCopied
        switch meeting {
        case .idle: facts.meeting = .idle
        case .recording: facts.meeting = .recording
        case .writing: facts.meeting = .writing
        }
        facts.hovering = hovering
        facts.messageFresh = fresh
        return facts
    }

    /// The one sentence of a message.
    func overlayMessage(_ t: Lang) -> String {
        if cancelArmed { return t("Press Esc again to cancel", "Premi di nuovo Esc per annullare") }
        if pressedWhileBusy { return t("Still writing the last one · speak again in a moment", "Scrivo ancora la precedente · riprova tra un attimo") }
        switch outcome {
        case .empty:
            if startedByVoice { let name = settings.voiceOptions.spokenName; return t("No speech heard. Say “Hey \(name)”, then speak.", "Nessuna voce sentita. Di’ “Ehi \(name)”, poi parla.") }
            return t("No speech heard", "Nessuna voce sentita")
        case .delivered where asSaid: return t("Pasted as said: the writing model didn’t answer", "Incollata com’era: il modello di scrittura non ha risposto")
        default: return t.message(status)
        }
    }

    /// × on the overlay, or Escape on its box: whatever it shows goes.
    func dismissOverlay() {
        if answer != nil { closeAnswer(); return }
        if pasteBox != nil { closePasteBox(); return }
        if meetingOffer != nil { declineMeetingOffer(); return }
        if meetingEnded != nil { keepCall(); return }
        if coach != nil { endCoach(); return }
        if let entry = pendingSuggestion { dismissSuggestion(entry); return }
        if canRestore { declineRestore(); return }
        outcome = .none; flashOutcome?()
    }

    /// Copia in the box, Return, or the copy keys while it is open: the text goes on the
    /// clipboard, the box says so, and closes a moment later.
    func copyPasteBox() {
        guard let text = pasteBox, !pasteCopied else { return }
        copy(text); pasteCopied = true; answerArmed = false
        let shown = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Motion.linger * 1_000_000_000))
            guard let self, self.pasteBox == shown, self.pasteCopied else { return }
            self.pasteBox = nil; self.pasteCopied = false; self.outcome = .copied; self.flashOutcome?()
        }
    }
    func closePasteBox() { pasteBox = nil; pasteCopied = false; answerArmed = false; flashOutcome?() }
}

/// The colours of the overlay where it is drawn: on the island's black, or on its own surface.
struct OverlayInk {
    let primary: Color, secondary: Color, tertiary: Color, accent: Color, fill: Color
    static func of(island: Bool) -> OverlayInk {
        island ? OverlayInk(primary: Palette.textOnNotch, secondary: Palette.textOnNotchSecondary, tertiary: Palette.textOnNotchSecondary.opacity(0.75), accent: Palette.accentOnNotch, fill: Palette.textOnNotch.opacity(0.14))
               : OverlayInk(primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary, accent: Palette.accent, fill: Palette.fillHover)
    }
}

// MARK: - The voice

extension LevelMeter {
    /// The moment to draw the voice of now: the clock itself, or the held moment in snapshots.
    func live(_ date: Date) -> Double { frozen.map { $0 - Self.delay } ?? date.timeIntervalSinceReferenceDate }
    /// The level of the last moments, averaged over a few hundredths of a second so the steps
    /// between deliveries of audio don't show.
    func recent(at time: Double) -> Double { Double(level(at: time) + level(at: time - 0.04) + level(at: time - 0.08)) / 3 }
}

/// The voice as four dots that stretch with it. With Reduce Motion they keep their height and
/// follow only the loudness.
struct VoiceDotsView: View {
    let meter: LevelMeter
    var color: Color
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion && meter.frozen == nil)) { timeline in
            let time = meter.live(timeline.date)
            let heights = VoiceDots.heights(level: meter.recent(at: time), time: reduceMotion ? 0 : time)
            HStack(spacing: 4 * scale) {
                ForEach(0..<VoiceDots.count, id: \.self) { index in
                    Capsule().fill(color).frame(width: 5 * scale, height: heights[index] * scale)
                }
            }
            .frame(height: 20 * scale)
        }
        .accessibilityHidden(true)
    }
}

/// The red dot of a live microphone, breathing with the voice of this moment.
struct BreathingDot: View {
    let meter: LevelMeter
    var color: Color
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion && meter.frozen == nil)) { timeline in
            let level = reduceMotion ? 0.3 : meter.recent(at: meter.live(timeline.date))
            ZStack {
                Circle().fill(color.opacity(0.22)).frame(width: size, height: size).scaleEffect(1.4 + level * 1.4)
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .accessibilityHidden(true)
    }
}

// MARK: - Symbols, keys and controls

/// The symbol for what is happening, on the left of the notch or first in the capsule.
struct LeadSymbol: View {
    @EnvironmentObject var model: AppModel
    let lead: OverlayScene.Lead
    let meter: LevelMeter
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let ink = OverlayInk.of(island: onIsland)
        Group {
            switch lead {
            case .mark, .answer: VerbMark(small: true).fill(ink.accent).frame(width: 16, height: 12)
            case .recording, .asking: BreathingDot(meter: meter, color: ink.accent)
            case .editing:
                HStack(spacing: 2) { BreathingDot(meter: meter, color: ink.accent); symbol("pencil", ink.accent) }
            case .working: InkDrops(width: 22, height: 14)
            case .rewriting: symbol("pencil", ink.accent)
            case .done(let asSaid): symbol("checkmark", asSaid ? Palette.warning : Palette.success, weight: .bold)
            case .copied: symbol("doc.on.doc", ink.primary)
            case .pasted: symbol("doc.on.clipboard", ink.primary)
            case .noSpeech: symbol("mic.slash", ink.secondary)
            case .cancelled: symbol("xmark.circle", ink.secondary)
            case .failed: symbol("exclamationmark.triangle", Palette.warning)
            case .hint: symbol("hand.point.up.left", Palette.warning)
            case .learned: symbol("character.book.closed", Palette.success)
            case .meeting:
                symbol("person.2", ink.primary).overlay(alignment: .topTrailing) { Circle().fill(ink.accent).frame(width: 7, height: 7).offset(x: 4, y: -2) }
            case .writingNotes: symbol("doc.text", ink.primary)
            case .call: symbol("person.2.wave.2", ink.primary)
            case .callEnded: symbol("phone.down", ink.primary)
            case .coach: symbol(coachSymbol, ink.primary)
            case .dictionary: symbol("character.book.closed", ink.primary)
            case .paste: symbol("doc.on.clipboard", ink.primary)
            }
        }
        .accessibilityHidden(true)
    }
    private var coachSymbol: String {
        switch model.coach { case .click?: "cursorarrow.click"; case .done?: "checkmark"; default: "mic" }
    }
    private func symbol(_ name: String, _ color: Color, weight: Font.Weight = .medium) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: weight)).foregroundStyle(color)
    }
}

/// A key drawn as a keycap, in the overlay's ink.
struct OverlayKeycap: View {
    let label: String
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let ink = OverlayInk.of(island: onIsland)
        Text(label).font(Typeface.text(TypeSize.caption, .semibold)).foregroundStyle(ink.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).strokeBorder(ink.secondary.opacity(0.45), lineWidth: 1))
    }
}

/// Keys as keycaps, one each: "⌃", "⌘", "C".
struct OverlayKeys: View {
    let binding: KeyBinding
    @Environment(\.lang) private var t
    var body: some View {
        HStack(spacing: 3) { ForEach(Array(binding.parts.enumerated()), id: \.offset) { OverlayKeycap(label: t.keys($0.element)) } }
    }
}

/// The small round buttons: a square to finish, a cross to close.
struct OverlayControl: View {
    enum Kind { case stop, close }
    let kind: Kind
    var size: CGFloat = 22
    let label: String
    let action: () -> Void
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let ink = OverlayInk.of(island: onIsland)
        Button(action: action) {
            ZStack {
                Circle().fill(kind == .stop ? ink.primary.opacity(0.16) : ink.fill)
                if kind == .stop { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ink.primary).frame(width: size * 0.36, height: size * 0.36) }
                else { Image(systemName: "xmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(ink.secondary) }
            }
            .frame(width: size, height: size)
            .padding(4).contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .help(label).accessibilityLabel(label)
    }
}

/// The last seconds of a hands-free dictation, counted down in a ring.
struct CountdownRing: View {
    let seconds: Int
    var body: some View {
        ZStack {
            Circle().stroke(Palette.warning.opacity(0.3), lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(seconds) / 3).stroke(Palette.warning, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(seconds)").font(Typeface.text(10, .bold)).monospacedDigit().foregroundStyle(Palette.warning)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// What goes on the right: numbers, keys and controls, never words.
struct TrailContent: View {
    @EnvironmentObject var model: AppModel
    let trail: OverlayScene.Trail
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let t = model.lang, ink = OverlayInk.of(island: onIsland)
        switch trail {
        case .none: EmptyView()
        case .key:
            if let keys = model.settings.keyOptions.dictation { OverlayKeys(binding: keys) }
        case .stop:
            HStack(spacing: Space.sm) {
                Text(durationLabel(model.elapsed)).font(Typeface.text(TypeSize.body)).monospacedDigit().foregroundStyle(model.lastMinute ? Palette.warning : ink.primary)
                OverlayControl(kind: .stop, label: t("Finish. Esc cancels.", "Termina. Esc annulla.")) { model.finish() }
            }
        case .time:
            if case .recording(let start) = model.meeting {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(durationLabel(context.date.timeIntervalSince(start))).font(Typeface.text(TypeSize.body)).monospacedDigit().foregroundStyle(ink.primary)
                }
            }
        case .countdown(let seconds):
            HStack(spacing: Space.sm) {
                CountdownRing(seconds: seconds)
                OverlayControl(kind: .stop, label: t("Finish. Esc cancels.", "Termina. Esc annulla.")) { model.finish() }
            }
        case .close:
            OverlayControl(kind: .close, label: t("Close", "Chiudi")) { model.dismissOverlay() }
        case .copied:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.success).frame(width: 30, height: 30).accessibilityHidden(true)
        }
    }
}

/// A button on the open overlay: filled for the main action, quieter for the others.
struct OverlayButton: View {
    let title: String
    var primary = false
    var symbol: String?
    let action: () -> Void
    @Environment(\.onIsland) private var onIsland
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let ink = OverlayInk.of(island: onIsland)
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(Typeface.text(TypeSize.footnote, .semibold))
            }
            .foregroundStyle(primary ? (onIsland ? Color.black : Palette.surfaceOverlay) : ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(primary ? ink.primary : ink.fill, in: Capsule())
            .fixedSize()
            .frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
    }
}

// MARK: - What it says, open

/// What the overlay says once it opens: below the notch, or above the capsule's row.
struct OverlayBody: View {
    @EnvironmentObject var model: AppModel
    let body_: OverlayScene.Body
    @Environment(\.onIsland) private var onIsland
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    var body: some View {
        let t = model.lang, ink = OverlayInk.of(island: onIsland)
        switch body_ {
        case .none: EmptyView()
        case .words(let edit):
            VStack(alignment: .leading, spacing: 4) {
                if edit { caption(t("Edit", "Modifica"), ink) }
                spoken(ink)
            }
        case .silence:
            VStack(alignment: .leading, spacing: 6) {
                spoken(ink)
                Text(t("Speak to go on", "Parla per continuare")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary)
            }
        case .message:
            Text(model.overlayMessage(t)).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.primary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case .choice: OverlayChoice()
        case .paste: PasteBoxBody()
        case .answer: AnswerBoxBody()
        case .detail: OverlayDetail()
        }
    }
    /// The words as they are heard: the settled ones in ink, the rest lighter.
    private func spoken(_ ink: OverlayInk) -> some View {
        let words = model.livePreview
        return Text(LivePreviewText.text(settled: words.settled, tentative: words.tentative, limit: 120, marked: withoutColor, ink: ink.primary, pencil: ink.secondary))
            .font(Typeface.text(TypeSize.body)).lineSpacing(leading(TypeSize.body, Leading.ui))
            .lineLimit(2).truncationMode(.head).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel([words.settled, words.tentative].filter { !$0.isEmpty }.joined(separator: " "))
            .accessibilityAddTraits(.updatesFrequently)
    }
    private func caption(_ text: String, _ ink: OverlayInk) -> some View {
        Text(text.uppercased()).font(Typeface.text(TypeSize.caption, .semibold)).tracking(0.6).foregroundStyle(ink.accent)
    }
}

/// The words of the live preview, the settled part in ink and the part still being heard lighter.
enum LivePreviewText {
    /// The last words only, so the newest are always in view: an early part that no longer
    /// fits gives way to an ellipsis, at a word boundary. `marked` sets the words still being
    /// heard in italic too, for Differentiate Without Colour.
    static func text(settled: String, tentative: String, limit: Int = 130, marked: Bool = false, ink: Color = Palette.textPrimary, pencil: Color = Palette.textTertiary) -> AttributedString {
        let gap = settled.isEmpty || tentative.isEmpty ? "" : " "
        var head = settled + gap, tail = tentative
        let excess = head.count + tail.count - limit
        if excess > 0 {
            if excess < head.count { head = String(head.dropFirst(excess)) } else { tail = String(tail.dropFirst(excess - head.count)); head = "" }
            if head.isEmpty { tail = "… " + tail.drop { !$0.isWhitespace }.drop { $0.isWhitespace } }
            else { head = "… " + head.drop { !$0.isWhitespace }.drop { $0.isWhitespace } }
        }
        let inkColor = ink, pencilColor = pencil
        var settledPart = AttributedString(head)
        settledPart.foregroundColor = inkColor
        var heard = AttributedString(tail)
        heard.foregroundColor = pencilColor
        if marked { heard.font = Typeface.text(TypeSize.body).italic() }
        settledPart.append(heard)
        return settledPart
    }
}

/// A sentence with its buttons: a call to record, a call that ended, a step of the first
/// dictation, a word to learn, a failure or a cancel.
struct OverlayChoice: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let t = model.lang
        HStack(spacing: Space.sm) {
            if let app = model.meetingOffer {
                lines(t("Call on \(app)", "Chiamata su \(app)"), t("Record it and write the notes?", "Registrarla e scrivere le note?"))
                OverlayButton(title: t("Record", "Registra"), primary: true) { model.acceptMeetingOffer() }
            } else if let app = model.meetingEnded {
                lines(t("Call on \(app) ended?", "Chiamata su \(app) finita?"), t("Stop and write the notes.", "Ferma e scrivi le note."))
                OverlayButton(title: t("Stop", "Ferma"), primary: true) { model.endCall() }
                OverlayButton(title: t("Keep going", "Continua")) { model.keepCall() }
            } else if let step = model.coach {
                lines(coachLine(step, t), nil)
            } else if let entry = model.pendingSuggestion {
                lines(t("Add “\(entry.word)” to the dictionary?", "Aggiungo «\(entry.word)» al dizionario?"),
                      entry.heardAs.isEmpty ? t("You corrected it after the dictation", "L’hai corretta dopo la dettatura") : t("Verb wrote “\(entry.heardAs)”", "Verb aveva scritto «\(entry.heardAs)»"))
                OverlayButton(title: t("Add", "Aggiungi"), primary: true) { model.acceptSuggestion(entry) }
                OverlayButton(title: t("No", "No")) { model.dismissSuggestion(entry) }
            } else if model.outcome == .failed {
                let reason = model.keptRecording ? t("Recording saved: retry it from History.", "Registrazione salvata: riprovala dalla Cronologia.")
                    : model.notice.map { t.message($0) }.flatMap { $0.components(separatedBy: ". ").first }
                lines(t("The dictation didn’t work", "La dettatura non è riuscita"), reason)
                OverlayButton(title: t("Why?", "Perché?")) { model.showProblem() }
            } else if model.canRestore {
                lines(t("Dictation cancelled", "Dettatura annullata"), nil)
                OverlayButton(title: t("Restore", "Ripristina"), symbol: "arrow.uturn.backward") { model.restoreCancelled() }
                    .help(t("Write down the dictation you just cancelled", "Trascrivi la dettatura appena annullata"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
    private func coachLine(_ step: CoachStep, _ t: Lang) -> String {
        let keys = model.settings.keyOptions.dictation.map { t.keys($0.label) } ?? "fn"
        switch step {
        case .click(let app, _): return t("In \(app), click where you write a message", "In \(app), clicca dove scrivi un messaggio")
        case .speak: return t("Now hold \(keys) and say your message", "Ora tieni \(keys) e di’ il tuo messaggio")
        case .done: return t("That’s it: it works the same in every app", "Ecco fatto: funziona così in ogni app")
        }
    }
    private func lines(_ title: String, _ detail: String?) -> some View {
        let ink = OverlayInk.of(island: onIsland)
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Typeface.text(TypeSize.body, detail == nil ? .regular : .semibold)).foregroundStyle(ink.primary).lineLimit(1)
            if let detail { Text(detail).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a symbol means, while the pointer is over it, with its button.
struct OverlayDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let t = model.lang, ink = OverlayInk.of(island: onIsland)
        HStack(spacing: Space.sm) {
            if model.busy {
                Text(model.compactTitle(t)).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.primary).lineLimit(1)
                Spacer(minLength: Space.sm)
                OverlayControl(kind: .close, label: t("Cancel", "Annulla")) { model.cancel() }.disabled(model.phase == .cancelling)
            } else if case .writing(let doing) = model.meeting {
                Text(t.message(doing)).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.primary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text(t("Recording the meeting", "Riunione in registrazione")).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.primary).lineLimit(1)
                Spacer(minLength: Space.sm)
                OverlayButton(title: t("Stop", "Ferma")) { model.stopMeeting() }
            }
        }
    }
}

/// A dictation that found no field: its text, Copy, and how to paste it.
struct PasteBoxBody: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let t = model.lang, ink = OverlayInk.of(island: onIsland), keys = model.settings.keyOptions
        VStack(alignment: .leading, spacing: Space.md) {
            ScrollView {
                Text(model.pasteBox ?? "").font(Typeface.text(TypeSize.body)).lineSpacing(leading(TypeSize.body, Leading.reading)).foregroundStyle(ink.primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            HStack(spacing: Space.sm) {
                if model.pasteCopied {
                    Label(t("Copied", "Copiata"), systemImage: "checkmark").font(Typeface.text(TypeSize.footnote, .semibold)).foregroundStyle(Palette.success)
                        .padding(.horizontal, 12).frame(height: 26).background(Palette.success.opacity(0.16), in: Capsule())
                    hint(t("paste it with", "incollala con"), KeyBinding(modifiers: [.command], keyCode: 9, label: "⌘ V"), ink)
                    Spacer(minLength: Space.sm)
                    Text(t("closes in 2 s", "si chiude tra 2 s")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary)
                } else {
                    OverlayButton(title: t("Copy", "Copia"), primary: true) { model.copyPasteBox() }
                    if let copy = keys.copyLast { hint(t("or", "o"), copy, ink) }
                    Spacer(minLength: Space.sm)
                    if let paste = keys.pasteLast { hint(nil, paste, ink, after: t("pastes where you click", "incolla dove clicchi")) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Not pasted: no text field", "Non incollata: nessun campo di testo"))
    }
    private func hint(_ before: String?, _ binding: KeyBinding, _ ink: OverlayInk, after: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let before { Text(before).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary) }
            OverlayKeys(binding: binding)
            if let after { Text(after).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary).lineLimit(1) }
        }
    }
}

/// A question and its answer: the words as you ask, the wait, then the answer, with the
/// questions before it while the box stays open.
struct AnswerBoxBody: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let t = model.lang, ink = OverlayInk.of(island: onIsland)
        VStack(alignment: .leading, spacing: Space.sm) {
            if model.phase == .recording || model.phase == .authorizing {
                Text(t("Question", "Domanda").uppercased()).font(Typeface.text(TypeSize.caption, .semibold)).tracking(0.6).foregroundStyle(ink.accent)
                let words = model.livePreview
                Text(LivePreviewText.text(settled: words.settled, tentative: words.tentative, limit: 200, ink: ink.primary, pencil: ink.secondary))
                    .font(Typeface.text(TypeSize.callout)).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    Text(t("Let go to ask", "Rilascia per chiedere")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary)
                    Spacer()
                    HStack(spacing: 5) { OverlayKeycap(label: "esc"); Text(t("cancels", "annulla")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary) }
                }
            } else if let card = model.answer {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            ForEach(Array(model.conversation.dropLast(card.streaming || card.text.isEmpty ? 0 : 1).enumerated()), id: \.offset) { _, turn in
                                question(turn.question, ink)
                                Text(AnswerText.rendered(turn.answer)).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.secondary).lineLimit(2)
                            }
                            question(card.request, ink)
                            if let problem = card.problem {
                                Text(t.message(problem)).font(Typeface.text(TypeSize.body)).foregroundStyle(ink.primary).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(Array(card.files.enumerated()), id: \.offset) { index, url in FileRow(url: url, first: index == 0) }
                            if card.streaming && card.text.isEmpty {
                                HStack(spacing: Space.sm) { InkDrops(width: 22, height: 14); Text(t("Thinking…", "Ci penso…")).font(Typeface.text(TypeSize.body).italic()).foregroundStyle(ink.secondary) }
                            } else if !card.text.isEmpty {
                                Text(AnswerText.rendered(card.text)).font(Typeface.text(TypeSize.body)).lineSpacing(leading(TypeSize.body, Leading.reading)).foregroundStyle(ink.primary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .onChange(of: card.text) { reader.scrollTo("end", anchor: .bottom) }
                }
                if !card.streaming, !card.text.isEmpty || !card.files.isEmpty {
                    HStack(spacing: Space.sm) {
                        if !card.files.isEmpty, card.text.isEmpty { OverlayButton(title: t("Open", "Apri"), primary: true) { model.useAnswer() } }
                        if !card.text.isEmpty { OverlayButton(title: t("Copy", "Copia"), primary: true) { model.copyAnswer() } }
                        if card.canInsert, !card.text.isEmpty { OverlayButton(title: t("Insert", "Inserisci")) { model.useAnswer() } }
                        Spacer(minLength: Space.sm)
                        if let ask = model.settings.keyOptions.ask {
                            HStack(spacing: 5) {
                                Text(t("hold", "tieni")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary)
                                OverlayKeys(binding: ask)
                                Text(t("to go on", "per continuare")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary)
                            }
                        }
                    }
                }
            } else {
                // Still writing the question down.
                let words = model.livePreview
                question([words.settled, words.tentative].filter { !$0.isEmpty }.joined(separator: " "), ink)
                HStack(spacing: Space.sm) { InkDrops(width: 22, height: 14); Text(t("Thinking…", "Ci penso…")).font(Typeface.text(TypeSize.body).italic()).foregroundStyle(ink.secondary) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Verb’s answer", "La risposta di Verb"))
    }
    private func question(_ text: String, _ ink: OverlayInk) -> some View {
        Text(text).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.secondary).lineLimit(2)
    }
}

enum AnswerText {
    /// Bold, italic, code and links as they read; list marks stay as written.
    static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}

/// A file found by a request: its icon, name and folder; a click opens it.
private struct FileRow: View {
    let url: URL
    let first: Bool
    @State private var hovering = false
    @Environment(\.onIsland) private var onIsland
    var body: some View {
        let ink = OverlayInk.of(island: onIsland)
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: Space.sm) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(Typeface.text(TypeSize.body, first ? .semibold : .regular)).foregroundStyle(ink.primary).lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Typeface.text(TypeSize.caption)).foregroundStyle(ink.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.sm).padding(.vertical, 5)
            .background(hovering ? ink.fill : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onPointerOver { hovering = $0 }
    }
}

/// A message keeps its words for a few seconds, then only its symbol: this says which.
struct MessageFreshness: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var fresh: Bool
    func body(content: Content) -> some View {
        content.task(id: "\(model.phase)|\(model.outcome)|\(model.status)|\(model.cancelArmed)|\(model.pressedWhileBusy)") {
            fresh = true
            try? await Task.sleep(nanoseconds: UInt64(Motion.message * 1_000_000_000))
            if !Task.isCancelled { fresh = false }
        }
    }
}
