import AppKit
import SwiftUI
import VerbCore

// The overlay in its styles. The notch style hangs from the top of the screen; the others sit at
// the bottom, above the Dock, and open upward. All of them show the same scene: on their row only
// symbols, numbers and keys, and words only once they open.

/// Whether the pointer is over the overlay. The panel never becomes key, where SwiftUI's own
/// hover tracking can't be relied on, so the host view follows the pointer and says so here.
@MainActor final class OverlayHover: ObservableObject {
    @Published var inside = false
    /// The screen the overlay is on, for the notch style: its notch, or none.
    @Published var island = IslandGeometry()
    /// The room left of the notch the menus of the app in front leave free; nil when unknown.
    @Published var leftRoom: CGFloat?
    /// The pointer is near the top of a screen without a notch, where the island waits.
    @Published var near = false
}

/// The overlay's host view: it notices the pointer entering and leaving the panel whatever app
/// is in front.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var hover: OverlayHover?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hover?.inside = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hover?.inside = false }
}

/// The overlay in the style chosen in Settings, at its own size: the panel fits around it.
struct OverlayView: View {
    @EnvironmentObject var model: AppModel
    let meter: LevelMeter
    var body: some View {
        Group {
            if model.settings.overlayStyle == .notch { NotchOverlay(meter: meter) } else { CapsuleOverlay(meter: meter) }
        }
        .fixedSize()
        .environment(\.lang, model.lang)
    }
}

struct OverlaySizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// What the panel holds: the overlay, which reports its size so the panel can fit around it.
struct OverlayRoot: View {
    @EnvironmentObject var model: AppModel
    let meter: LevelMeter
    let resized: (CGSize) -> Void
    var body: some View {
        OverlayView(meter: meter)
            .background(GeometryReader { Color.clear.preference(key: OverlaySizeKey.self, value: $0.size) })
            .onPreferenceChange(OverlaySizeKey.self) { resized($0) }
            // The notch style hangs from the top while the panel catches up with its size; the
            // others keep their bottom edge, and grow upward.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.settings.overlayStyle == .notch ? .top : .bottom)
    }
}

// MARK: - At the bottom of the screen

/// The styles at the bottom: Classic, Pill, Voice, Dot and Bar. They differ only in their row
/// while you speak; everything else is a symbol in a capsule, and words open it upward.
struct CapsuleOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    @State private var fresh = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let t = model.lang, style = model.settings.overlayStyle
        let scene = OverlayScene.of(model.overlayFacts(hovering: hover.inside, fresh: fresh))
        Group {
            if scene.isOpen { open(scene, style).accessibilityElement(children: .contain).accessibilityLabel("Verb") }
            else if !scene.isEmpty { closed(scene, style).compactAccessibility(model, t) }
            else { Color.clear.frame(width: 1, height: 1) }
        }
        .modifier(MessageFreshness(fresh: $fresh))
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: scene)
    }

    private var recording: Bool { model.phase == .recording || model.phase == .authorizing }
    /// Stop shows under the pointer, and always without Accessibility, when Space and Escape can't finish.
    private var stopShown: Bool { hover.inside || model.keysCantFinish }

    @ViewBuilder private func closed(_ scene: OverlayScene, _ style: OverlayStyle) -> some View {
        if recording, scene.lead == .recording || scene.lead == .editing {
            row(scene, style, open: false)
        } else if style == .dot {
            ZStack { if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) } }
                .frame(width: 40, height: 40)
                .overlaySurface(Circle())
        } else {
            HStack(spacing: Space.sm) {
                if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
                TrailContent(trail: scene.trail)
            }
            .padding(.horizontal, scene.trail == .none ? 0 : 12)
            .frame(minWidth: Self.height(style) + 8, minHeight: Self.height(style))
            .overlaySurface(style == .bar ? AnyInsettableShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)) : AnyInsettableShape(Capsule()))
        }
    }

    /// Open: one shape that grows upward, the words on top and the row at the bottom, still.
    private func open(_ scene: OverlayScene, _ style: OverlayStyle) -> some View {
        let box = scene.body == .paste || scene.body == .answer
        return VStack(spacing: 0) {
            OverlayBody(body_: scene.body)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, Space.xs)
                .frame(maxWidth: .infinity, maxHeight: box ? .infinity : nil, alignment: .topLeading)
            Group {
                if recording, scene.lead == .recording || scene.lead == .editing, scene.body != .answer { row(scene, style, open: true) }
                else {
                    HStack(spacing: Space.sm) {
                        if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
                        Spacer(minLength: 0)
                        TrailContent(trail: scene.trail)
                    }
                    .padding(.leading, 18).padding(.trailing, scene.trail == .none ? 18 : 8)
                }
            }
            .frame(height: style == .classic ? 44 : 36)
        }
        .frame(width: Sizing.overlayOpenWidth, height: box ? Sizing.overlayBoxHeight : nil)
        .overlaySurface(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    }

    /// The row while you speak, in each style's own way.
    @ViewBuilder private func row(_ scene: OverlayScene, _ style: OverlayStyle, open: Bool) -> some View {
        let t = model.lang
        let finish = OverlayControl(kind: .stop, size: style == .classic ? 28 : 22, label: t("Finish. Esc cancels.", "Termina. Esc annulla.")) { model.finish() }
        let countdown: Int? = { if case .countdown(let seconds) = scene.trail { return seconds }; return nil }()
        switch style {
        case .classic:
            HStack(spacing: 10) {
                lead(scene)
                VoiceDotsView(meter: meter, color: Palette.textPrimary)
                if model.soundLowered { SoundLoweredMark() }
                Spacer(minLength: Space.sm)
                if let countdown { CountdownRing(seconds: countdown) } else { time }
                OverlayKeycap(label: finishKey(t))
                finish
            }
            .padding(.leading, 18).padding(.trailing, 8)
            .frame(minWidth: open ? nil : 214)
            .frame(height: 44)
            .modifier(Surfaced(on: !open, shape: Capsule()))
        case .pill, .notch:
            HStack(spacing: Space.sm) {
                lead(scene)
                VoiceDotsView(meter: meter, color: Palette.textPrimary)
                if open { Spacer(minLength: 0); if let countdown { CountdownRing(seconds: countdown) } }
                if open || stopShown { finish }
            }
            .padding(.leading, 14).padding(.trailing, open || stopShown ? 7 : 14)
            .frame(height: 36)
            .modifier(Surfaced(on: !open, shape: Capsule()))
        case .ink:
            HStack(spacing: Space.sm) {
                if open { Spacer(minLength: 0) }
                VoiceDotsView(meter: meter, color: Palette.accent, scale: 0.9)
                if open { Spacer(minLength: 0); if let countdown { CountdownRing(seconds: countdown) } }
                if open || stopShown { finish }
            }
            .padding(.leading, 12).padding(.trailing, open || stopShown ? 4 : 12)
            .frame(height: open ? 36 : 30)
            .modifier(Surfaced(on: !open, shape: Capsule()))
        case .dot:
            if open {
                HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    VoiceDotsView(meter: meter, color: Palette.textPrimary, scale: 0.85)
                    Spacer(minLength: 0)
                    if let countdown { CountdownRing(seconds: countdown) }
                    finish
                }
                .padding(.horizontal, 7).frame(height: 36)
            } else {
                Button { model.finish() } label: {
                    ZStack {
                        if hover.inside { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.textPrimary).frame(width: 11, height: 11) }
                        else { VoiceDotsView(meter: meter, color: Palette.textPrimary, scale: 0.75) }
                    }
                    .frame(width: 40, height: 40).contentShape(Circle())
                }
                .buttonStyle(PlainPressStyle())
                .overlaySurface(Circle())
                .help(t("Finish. Esc cancels.", "Termina. Esc annulla."))
            }
        case .bar:
            HStack(spacing: Space.sm) {
                BreathingDot(meter: meter, color: Palette.accent, size: 7)
                Text(durationLabel(model.elapsed)).font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(model.lastMinute ? Palette.warning : Palette.textSecondary)
                VoiceDotsView(meter: meter, color: Palette.textPrimary, scale: 0.8)
                if open { Spacer(minLength: 0); if let countdown { CountdownRing(seconds: countdown) } }
                if open || stopShown { finish }
            }
            .padding(.leading, 10).padding(.trailing, open || stopShown ? 4 : 10)
            .frame(height: open ? 36 : 30)
            .modifier(Surfaced(on: !open, shape: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)))
        }
    }

    @ViewBuilder private func lead(_ scene: OverlayScene) -> some View {
        if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
    }
    private var time: some View {
        Text(durationLabel(model.elapsed)).font(Typeface.text(TypeSize.body)).monospacedDigit().foregroundStyle(model.lastMinute ? Palette.warning : Palette.textPrimary)
    }
    /// The key that finishes: Space once hands-free, otherwise the dictation key to let go.
    private func finishKey(_ t: Lang) -> String {
        if model.handsFree { return t("space", "spazio") }
        return model.settings.keyOptions.dictation.map { t.keys($0.label) } ?? t("space", "spazio")
    }
    static func height(_ style: OverlayStyle) -> CGFloat {
        switch style { case .classic: 44; case .dot: 40; case .ink, .bar: 30; case .pill, .notch: 36 }
    }
}

/// The overlay's own surface on a closed row; an open overlay draws one around everything.
private struct Surfaced<S: InsettableShape>: ViewModifier {
    let on: Bool
    let shape: S
    func body(content: Content) -> some View {
        if on { content.overlaySurface(shape) } else { content }
    }
}

/// Any rounded shape, for a capsule or the Bar's rectangle.
struct AnyInsettableShape: InsettableShape {
    private let path: @Sendable (CGRect) -> Path
    private let inset: @Sendable (CGFloat) -> AnyInsettableShape
    init<S: InsettableShape>(_ shape: S) {
        path = { shape.path(in: $0) }
        inset = { AnyInsettableShape(shape.inset(by: $0)) }
    }
    func path(in rect: CGRect) -> Path { path(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { inset(amount) }
}

extension View {
    /// The overlay's own surface over other apps: lighter than any card at night, with a firm
    /// edge, so it holds over a dark editor, a terminal, a video or a white page alike.
    func overlaySurface<S: InsettableShape>(_ shape: S) -> some View { modifier(OverlaySurface(shape: shape)) }
    /// One element for VoiceOver, which can finish and cancel although the buttons are hidden.
    func compactAccessibility(_ model: AppModel, _ t: Lang) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Verb, " + model.compactTitle(t))
            .accessibilityAction(named: t("Finish dictation", "Termina la dettatura")) { model.finish() }
            .accessibilityAction(named: t("Cancel dictation", "Annulla la dettatura")) { model.cancel() }
            .accessibilityAction(named: t("Restore the cancelled dictation", "Ripristina la dettatura annullata")) { model.restoreCancelled() }
    }
}

/// The Mac's sound is down while you speak, because of Verb: it comes back when you stop.
struct SoundLoweredMark: View {
    @Environment(\.lang) private var t
    var body: some View {
        Image(systemName: "speaker.wave.1.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textTertiary)
            .help(t("Sound turned down while you speak", "Audio abbassato mentre parli"))
            .accessibilityLabel(t("Sound turned down while you speak", "Audio abbassato mentre parli"))
    }
}

/// How the last dictation ended, as one mark.
struct OutcomeIcon: View {
    let outcome: Outcome
    /// Pasted as said, because the writing model failed or took too long: a tick, in the warning colour.
    var asSaid = false
    var body: some View { mark.accessibilityHidden(true) }
    /// The words beside it say the same; VoiceOver hears those.
    @ViewBuilder private var mark: some View {
        switch outcome {
        case .delivered: Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(asSaid ? Palette.warning : Palette.success)
        // Not pasted: the text waits as the last dictation, which is no success.
        case .copyOnly: Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.warning)
        case .copied: Image(systemName: "doc.on.clipboard").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.success)
        case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.warning)
        case .cancelled: Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textSecondary)
        case .empty: Image(systemName: "mic.slash").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
        case .hint: Image(systemName: "hand.point.up.left").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.warning)
        case .learned: Image(systemName: "character.book.closed").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.success)
        case .none: VerbMark(small: true).fill(Palette.accent).frame(width: 18, height: 13)
        }
    }
}

/// An arc of ink that turns while Verb works. SwiftUI draws it, so snapshots show it too.
struct InkSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle().trim(from: 0.1, to: 0.72)
                .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: max(1.5, size / 9), lineCap: .round))
                .rotationEffect(.degrees(turn))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// While the writing model works, as in a voice edit or a transform: three drops of ink rise
/// one after the other, the last one red, the sign of waiting everyone knows. It is not the
/// transcription's spinner, so a longer wait reads as the model at work. With Reduce Motion the
/// drops stand still.
struct InkDrops: View {
    var width: CGFloat = 24
    var height: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One round of the three drops, in seconds.
    static let period = 1.1
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let moment = reduceMotion ? 0.55 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in Self.draw(at: moment, in: &context, size: size) }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    static func draw(at moment: Double, in context: inout GraphicsContext, size: CGSize) {
        let radius = max(1.6, size.height * 0.12), gap = radius * 3.1
        for index in 0..<3 {
            // Each drop a little after the one before; it rises, then rests.
            var phase = (moment / period - Double(index) * 0.16).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            let lift = CGFloat(max(0, sin(phase * 2 * .pi)))
            let center = CGPoint(x: size.width / 2 + CGFloat(index - 1) * gap, y: size.height / 2 + radius * 0.6 - lift * size.height * 0.24)
            let color = index == 2 ? Palette.accent : Palette.textPrimary
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(0.35 + 0.65 * lift)))
        }
    }
}

/// Words with a band of ink passing through them, left to right, while the writing model works.
/// Otherwise, and with Reduce Motion, they are plain.
struct ShimmerText: View {
    let text: String
    let font: Font
    var shimmer = true
    var plain: Color = Palette.textPrimary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let period = 1.8
    /// Plain words for the snapshot renderer, whose off-screen windows would catch the band half-way.
    static var still = false
    var body: some View {
        if shimmer && !reduceMotion && !Self.still {
            TimelineView(.animation) { timeline in
                // The band starts before the first letter and leaves after the last.
                let at = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period * 1.8 - 0.4
                Text(text).font(font).lineLimit(1)
                    .foregroundStyle(LinearGradient(colors: [Palette.textTertiary, Palette.textPrimary, Palette.textTertiary], startPoint: UnitPoint(x: at - 0.3, y: 0.5), endPoint: UnitPoint(x: at + 0.3, y: 0.5)))
            }
        } else {
            Text(text).font(font).foregroundStyle(plain).lineLimit(1)
        }
    }
}

extension AppModel {
    /// A cancelled dictation can still be written down, and the overlay offers it.
    var canRestore: Bool { phase == .idle && outcome == .cancelled && restorable != nil }
    /// A few words for the compact styles: what is happening, or how it ended.
    func compactTitle(_ t: Lang) -> String {
        switch phase {
        case .idle:
            switch outcome {
            case .delivered: return asSaid ? t("Pasted as said", "Incollata com’era") : t.count(latestText.split(whereSeparator: \.isWhitespace).count, "word", "words", "parola", "parole")
            case .copied: return t("Copied · press ⌘\u{00A0}V", "Copiata · premi ⌘\u{00A0}V")
            case .copyOnly:
                // The reason first, as the note says it, then the way to paste it.
                let reason = t.message(status).components(separatedBy: " · ").first ?? t("Not pasted", "Non incollata")
                guard let paste = settings.keyOptions.pasteLast.map({ t.keys($0.label) }) else { return reason }
                return reason + " · " + t("\(paste) pastes it", "\(paste) la incolla")
            case .failed: return keptRecording ? t("Didn’t work · recording saved", "Non riuscita · registrazione salvata") : t("Didn’t work · see Verb", "Non riuscita · vedi Verb")
            case .cancelled: return t("Cancelled", "Annullata")
            case .empty: return t("No speech", "Nessuna voce")
            case .hint, .learned: return t.message(status)
            case .none: return "Verb"
            }
        case .authorizing: return t("One moment", "Un attimo")
        default: return pressedWhileBusy ? t("Wait · still writing", "Aspetta · sto scrivendo") : phaseTitle(t)
        }
    }
}
