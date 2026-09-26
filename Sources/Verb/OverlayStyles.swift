import AppKit
import SwiftUI
import VerbCore

// The overlay in its five styles. The compact ones keep to the essentials, a dot and the ink,
// and show their small buttons only while the pointer is over them. Space and Escape finish
// and cancel as always.

/// Whether the pointer is over the overlay. The panel never becomes key, where SwiftUI's own
/// hover tracking can't be relied on, so the host view follows the pointer and says so here.
@MainActor final class OverlayHover: ObservableObject {
    @Published var inside = false
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
            if model.phase == .idle, let entry = model.pendingSuggestion {
                SuggestionPrompt(entry: entry)
            } else {
                styled
            }
        }
        .fixedSize()
        .environment(\.lang, model.lang)
    }
    @ViewBuilder private var styled: some View {
        Group {
            switch model.settings.overlayStyle {
            case .classic: ClassicOverlay(meter: meter)
            case .pill: PillOverlay(meter: meter)
            case .ink: InkOverlay(meter: meter)
            case .dot: DotOverlay(meter: meter)
            case .bar: BarOverlay(meter: meter)
            }
        }
    }
}

struct OverlaySizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// What the panel holds: the overlay, which reports its size so the panel can fit around it.
struct OverlayRoot: View {
    let meter: LevelMeter
    let resized: (CGSize) -> Void
    var body: some View {
        OverlayView(meter: meter)
            .background(GeometryReader { Color.clear.preference(key: OverlaySizeKey.self, value: $0.size) })
            .onPreferenceChange(OverlaySizeKey.self) { resized($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The compact styles

/// A small pill: the red dot and the ink stroke. Under the pointer, a stop button covers the
/// end of the stroke.
struct PillOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let t = model.lang
        HStack(spacing: Space.sm) {
            switch model.phase {
            case .recording:
                LiveDot(meter: meter, size: 16)
                InkStroke(meter: meter, still: reduceMotion).frame(width: 78, height: 22)
                    .overlay(alignment: .trailing) { MiniButton(kind: .stop) { model.finish() }.revealed(hover.inside).offset(x: 4) }
            case .idle:
                OutcomeIcon(outcome: model.outcome).frame(width: 16)
                CompactCaption(text: model.compactTitle(t))
                if model.canRestore { RestoreButton() }
            default:
                if model.modelAtWork { InkDrops(width: 24, height: 14) } else { InkSpinner(size: 14).frame(width: 16) }
                // Room is kept for the cancel button, so it never covers the words.
                WorkingCaption(text: model.compactTitle(t), shimmer: model.modelAtWork).padding(.trailing, 26).frame(minWidth: 78, alignment: .leading)
                    .overlay(alignment: .trailing) { MiniButton(kind: .cancel) { model.cancel() }.revealed(hover.inside && model.phase != .cancelling).offset(x: 4) }
            }
        }
        .padding(.leading, 10).padding(.trailing, 7)
        .frame(height: 36)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.borderSubtle))
        .compactAccessibility(model, t)
    }
}

/// The ink stroke alone, with a red nib where the new ink appears. Under the pointer, the nib
/// gives way to the stop button.
struct InkOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let t = model.lang
        Group {
            switch model.phase {
            case .recording:
                InkStroke(meter: meter, still: reduceMotion, nib: hover.inside ? nil : Palette.accent).frame(width: 96, height: 20)
                    .overlay(alignment: .trailing) { MiniButton(kind: .stop, size: 20) { model.finish() }.revealed(hover.inside).offset(x: 7) }
            case .idle:
                HStack(spacing: Space.sm) {
                    OutcomeIcon(outcome: model.outcome)
                    CompactCaption(text: model.compactTitle(t))
                    if model.canRestore { RestoreButton() }
                }
            default:
                Group { if model.modelAtWork { InkDrops(width: 34, height: 18) } else { InkScan() } }.frame(width: 96, height: 20)
                    .overlay(alignment: .trailing) { MiniButton(kind: .cancel, size: 20) { model.cancel() }.revealed(hover.inside && model.phase != .cancelling).offset(x: 7) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.borderSubtle))
        .compactAccessibility(model, t)
    }
}

/// One dot that breathes with your voice, the smallest overlay. Under the pointer the dot
/// becomes a stop square, and the whole circle is the button.
struct DotOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    var body: some View {
        let t = model.lang
        Group {
            if model.phase == .idle {
                HStack(spacing: Space.sm) {
                    OutcomeIcon(outcome: model.outcome)
                    CompactCaption(text: model.compactTitle(t))
                    if model.canRestore { RestoreButton() }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Palette.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.borderSubtle))
            } else {
                let recording = model.phase == .recording
                Button { recording ? model.finish() : model.cancel() } label: {
                    ZStack {
                        Circle().fill(Palette.surfaceRaised)
                        Circle().strokeBorder(hover.inside ? Palette.textPrimary : Palette.borderSubtle, lineWidth: hover.inside ? 1.25 : 1)
                        if hover.inside {
                            if recording { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.textPrimary).frame(width: 11, height: 11) }
                            else { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textSecondary) }
                        } else if recording {
                            LiveDot(meter: meter, size: 26)
                        } else if model.modelAtWork {
                            InkDrops(width: 26, height: 18)
                        } else {
                            InkSpinner(size: 16)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                }
                .buttonStyle(PlainPressStyle())
                .disabled(model.phase == .cancelling || model.phase == .authorizing)
                .animation(.easeOut(duration: Motion.fast), value: hover.inside)
            }
        }
        .compactAccessibility(model, t)
    }
}

/// A slim bar with the time and the ink stroke. Under the pointer, a stop button covers the end
/// of the stroke.
struct BarOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let t = model.lang
        HStack(spacing: Space.sm) {
            switch model.phase {
            case .recording:
                LiveDot(meter: meter, size: 12)
                Text(durationLabel(model.elapsed)).font(Typeface.mono(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                    .frame(width: 30, alignment: .leading)
                InkStroke(meter: meter, still: reduceMotion).frame(width: 96, height: 18)
                    .overlay(alignment: .trailing) { MiniButton(kind: .stop, size: 20) { model.finish() }.revealed(hover.inside).offset(x: 4) }
            case .idle:
                OutcomeIcon(outcome: model.outcome).frame(width: 14)
                CompactCaption(text: model.compactTitle(t))
                if model.canRestore { RestoreButton() }
            default:
                if model.modelAtWork { InkDrops(width: 20, height: 12) } else { InkSpinner(size: 12) }
                ShimmerText(text: model.compactTitle(t), font: Typeface.text(TypeSize.caption, .medium), shimmer: model.modelAtWork, plain: Palette.textSecondary)
                    .frame(minWidth: 134, alignment: .leading)
                    .overlay(alignment: .trailing) { MiniButton(kind: .cancel, size: 20) { model.cancel() }.revealed(hover.inside && model.phase != .cancelling).offset(x: 4) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderSubtle))
        .compactAccessibility(model, t)
    }
}

// MARK: - Shared pieces

/// The small round button of the compact styles: an ink square to finish, a cross to cancel.
/// It looks 22 points wide and answers a little beyond its edge.
struct MiniButton: View {
    enum Kind { case stop, cancel }
    let kind: Kind
    var size: CGFloat = 22
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Palette.surfaceRaised)
                Circle().strokeBorder(kind == .stop ? Palette.textPrimary : Palette.borderStrong, lineWidth: 1.25)
                if kind == .stop {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Palette.textPrimary).frame(width: size * 0.34, height: size * 0.34)
                } else {
                    Image(systemName: "xmark").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: size, height: size)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
    }
}

private extension View {
    /// Shown, and clickable, only while the pointer is over the overlay.
    func revealed(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.6).allowsHitTesting(shown)
            .animation(.easeOut(duration: Motion.fast), value: shown)
    }
    /// One element for VoiceOver, which can finish and cancel although the buttons are hidden.
    func compactAccessibility(_ model: AppModel, _ t: Lang) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Verb, " + model.compactTitle(t))
            .accessibilityAction(named: t("Finish dictation", "Termina la dettatura")) { model.finish() }
            .accessibilityAction(named: t("Cancel dictation", "Annulla la dettatura")) { model.cancel() }
            .accessibilityAction(named: t("Restore the cancelled dictation", "Ripristina la dettatura annullata")) { model.restoreCancelled() }
    }
}

/// After a cancel, the recording is kept for a few seconds: this writes it down after all.
struct RestoreButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let t = model.lang
        Button { model.restoreCancelled() } label: {
            // It keeps its words: a narrow overlay shortens the caption beside it instead.
            Label(t("Restore", "Ripristina"), systemImage: "arrow.uturn.backward")
                .font(Typeface.text(TypeSize.footnote, .semibold)).foregroundStyle(Palette.textPrimary)
                .fixedSize()
                .padding(.horizontal, 10).frame(height: 26)
                .background(Palette.fillHover, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PlainPressStyle())
        .help(t("Write down the dictation you just cancelled", "Trascrivi la dettatura appena annullata"))
    }
}

private struct CompactCaption: View {
    let text: String
    var body: some View { Text(text).font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1) }
}

/// What Verb is doing, in the italic of the words themselves.
private struct WorkingCaption: View {
    let text: String
    var shimmer = false
    var body: some View { ShimmerText(text: text, font: Typeface.display(TypeSize.body).italic(), shimmer: shimmer) }
}

/// How the last dictation ended, as one mark.
struct OutcomeIcon: View {
    let outcome: Outcome
    var body: some View {
        switch outcome {
        case .delivered, .copyOnly: Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.success)
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

/// While Verb works in the ink style: a hairline with the red nib travelling along it.
private struct InkScan: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.5 : (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4) + 1) / 2
            Canvas { context, size in
                let mid = size.height / 2
                context.fill(Path(CGRect(x: 0, y: mid - 0.6, width: size.width, height: 1.2)), with: .color(Palette.textTertiary))
                let x = 4 + (size.width - 8) * phase
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: mid - 3, width: 6, height: 6)), with: .color(Palette.accent))
            }
        }
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
            case .delivered: return t.count(latestText.split(whereSeparator: \.isWhitespace).count, "word", "words", "parola", "parole")
            case .copied: return t("Copied · press ⌘V", "Copiata · premi ⌘V")
            case .copyOnly: let paste = t.keys(settings.keyOptions.pasteLast); return t("Ready · \(paste) pastes it", "Pronta · \(paste) la incolla")
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
