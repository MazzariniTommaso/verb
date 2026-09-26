import AppKit
import SwiftUI
import VerbCore

@MainActor final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The full capsule: what is happening, how to finish, the ink stroke and a stop button.
struct ClassicOverlay: View {
    @EnvironmentObject var model: AppModel
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let t = model.lang
        HStack(spacing: Space.md) {
            leading.frame(width: 20, height: 20)
            if model.phase == .recording {
                // The words keep their natural width; the stroke gives way, from 150 down to 110 pt.
                words(t).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                InkStroke(meter: meter, still: reduceMotion).frame(minWidth: 110, idealWidth: 150, maxWidth: 150, minHeight: 32, maxHeight: 32)
                Button { model.finish() } label: { StopRing() }
                .buttonStyle(PlainPressStyle())
                .help(t("Finish dictation. Esc cancels.", "Termina la dettatura. Esc annulla.")).accessibilityLabel(t("Finish dictation", "Termina la dettatura"))
            } else if model.busy {
                words(t).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        .frame(width: 32, height: 32).background(Palette.fillHover, in: Circle())
                        .frame(width: Sizing.controlMin, height: Sizing.controlMin).contentShape(Circle())
                }
                .buttonStyle(PlainPressStyle())
                .help(t("Cancel dictation", "Annulla la dettatura")).accessibilityLabel(t("Cancel dictation", "Annulla la dettatura"))
            } else {
                words(t).frame(maxWidth: .infinity, alignment: .leading)
                if model.canRestore { RestoreButton().padding(.trailing, Space.sm) }
            }
        }
        .padding(.leading, Space.lg).padding(.trailing, Space.sm)
        .frame(width: Sizing.overlayWidth, height: Sizing.overlayHeight)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.borderSubtle))
        .environment(\.lang, t)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verb")
    }

    private func words(_ t: Lang) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The one voice moment on screen, so it is set in New York italic, like the words themselves.
            ShimmerText(text: model.phaseTitle(t), font: Typeface.display(TypeSize.callout).italic(), shimmer: model.modelAtWork)
            Text(subtitle(t)).font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .recording: LiveDot(meter: meter)
        case .idle: OutcomeIcon(outcome: model.outcome)
        default: if model.modelAtWork { InkDrops(width: 20, height: 14) } else { InkSpinner(size: 16) }
        }
    }

    private func subtitle(_ t: Lang) -> String {
        switch model.phase {
        case .recording:
            // Started by voice, the way to finish is said too; otherwise it is the key.
            let voice = model.settings.voiceOptions, byVoice = model.startedByVoice && voice.stopCommands
            let closing = voice.spokenName + " " + (voice.finishWords.first ?? "stop")
            let finish = !model.handsFree ? t("Release to finish", "Rilascia per finire") : byVoice ? t("“Hey \(closing)” to finish", "“Ehi \(closing)” per finire") : t("Space to finish", "Spazio per finire")
            return durationLabel(model.elapsed) + " · " + finish
        case .authorizing: return t("One moment", "Un attimo")
        case .idle:
            let paste = t.keys(model.settings.keyOptions.pasteLast), copy = t.keys(model.settings.keyOptions.copyLast)
            switch model.outcome {
            case .delivered: return t.count(model.latestText.split(whereSeparator: \.isWhitespace).count, "word", "words", "parola", "parole") + " · " + t("\(paste) pastes it again", "\(paste) la incolla di nuovo")
            case .copied: return t("Press ⌘V where you want it", "Premi ⌘V dove vuoi incollarla")
            case .copyOnly: return t("\(paste) pastes it · \(copy) copies it", "\(paste) la incolla · \(copy) la copia")
            case .failed:
                return model.keptRecording ? t("Recording saved. Retry from History.", "Registrazione salvata. Riprova dalla Cronologia.")
                                           : t("The reason is in Verb’s window.", "Il motivo è nella finestra di Verb.")
            case .cancelled:
                if model.restorable != nil { return t("Still here for a few seconds.", "Resta qui per qualche secondo.") }
                return model.keptRecording ? t("Recording saved in History.", "Registrazione salvata nella Cronologia.") : ""
            case .empty:
                if model.startedByVoice { let name = model.settings.voiceOptions.spokenName; return t("Say “Hey \(name)”, then speak.", "Di’ “Ehi \(name)”, poi parla.") }
                let keys = t.keys(model.settings.keyOptions.dictation)
                return t("Speak while you hold \(keys).", "Parla mentre tieni premuto \(keys).")
            default: return ""
            }
        default:
            // The keys went down while this was still being written: nothing is recording.
            return model.pressedWhileBusy ? t("Still writing the last one · speak again in a moment", "Scrivo ancora la precedente · riparla tra un attimo") : model.location(t)
        }
    }
}

/// The words as they are spoken, on a card above the overlay. What has settled is ink; the
/// part still being heard is lighter and may change. The card sits in a panel of its own that
/// never takes a click, so it can't get in the way of the app underneath.
struct LivePreviewView: View {
    @EnvironmentObject var model: AppModel
    /// Room around the card for its shadow.
    static let margin: CGFloat = 16
    /// How far the panel reaches down over the capsule, so the card stands 8 pt above it.
    static let overlap: CGFloat = margin - Space.sm
    static let size = NSSize(width: Sizing.overlayWidth + margin * 2, height: 118)
    var body: some View {
        let words = model.livePreview
        let shown = model.settings.livePreview && model.busy && !(words.settled.isEmpty && words.tentative.isEmpty)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if shown {
                Text(Self.text(settled: words.settled, tentative: words.tentative))
                    .font(Typeface.display(TypeSize.callout)).lineSpacing(leading(TypeSize.callout, Leading.ui))
                    .lineLimit(3).truncationMode(.head).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                    .background(Palette.surfaceRaised.opacity(0.94), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
                    .shadow(color: Palette.shadow.opacity(0.6), radius: 10, y: 3)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([words.settled, words.tentative].filter { !$0.isEmpty }.joined(separator: " "))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, Self.margin).padding(.top, Self.margin).padding(.bottom, Self.margin)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeOut(duration: Motion.base), value: shown)
    }

    /// The last words only, so the newest are always in view: an early part that no longer
    /// fits gives way to an ellipsis, at a word boundary.
    static func text(settled: String, tentative: String, limit: Int = 130) -> AttributedString {
        let gap = settled.isEmpty || tentative.isEmpty ? "" : " "
        var head = settled + gap, tail = tentative
        let excess = head.count + tail.count - limit
        if excess > 0 {
            if excess < head.count { head = String(head.dropFirst(excess)) } else { tail = String(tail.dropFirst(excess - head.count)); head = "" }
            if head.isEmpty { tail = "… " + tail.drop { !$0.isWhitespace }.drop { $0.isWhitespace } }
            else { head = "… " + head.drop { !$0.isWhitespace }.drop { $0.isWhitespace } }
        }
        var ink = AttributedString(head)
        ink.foregroundColor = Palette.textPrimary
        var pencil = AttributedString(tail)
        pencil.foregroundColor = Palette.textTertiary
        ink.append(pencil)
        return ink
    }
}

/// Finish: an ink ring around a small square, light enough that the stroke beside it leads.
private struct StopRing: View {
    @State private var hovering = false
    var body: some View {
        ZStack {
            Circle().fill(hovering ? Palette.fillHover : .clear)
            Circle().strokeBorder(Palette.textPrimary, lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Palette.textPrimary).frame(width: 10, height: 10)
        }
        .frame(width: 34, height: 34)
        .frame(width: Sizing.controlMin, height: Sizing.controlMin)
        .contentShape(Circle())
        .onHover { hovering = $0 }
    }
}

/// The voice drawn as a line of ink: the nib presses harder as you speak louder. New ink
/// appears on the right and the line drifts left, like paper passing under a pen. It is drawn
/// on every frame of the display, up to 120 times a second on a ProMotion screen, from levels
/// measured every 10 ms. With Reduce Motion the line stays put and only its weight follows the voice.
struct InkStroke: View {
    let meter: LevelMeter
    var active = true
    var still = false
    var color: Color = Palette.textPrimary
    /// A red nib at the right end, where the new ink appears.
    var nib: Color? = nil
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { timeline in
            let now = meter.now(timeline.date)
            Canvas { context, size in Self.draw(meter, at: now, still: still, color: color, nib: nib, in: &context, size: size) }
        }
        // Older ink fades toward the left, as if drying.
        .mask(LinearGradient(colors: [.black.opacity(0.3), .black], startPoint: .leading, endPoint: .trailing))
        .accessibilityHidden(true)
    }

    private static func draw(_ meter: LevelMeter, at now: Double, still: Bool, color: Color, nib: Color?, in context: inout GraphicsContext, size: CGSize) {
        let count = max(16, Int(size.width / 2))
        let span = Double(size.width) / LevelMeter.speed
        let spacing = size.width / CGFloat(count - 1), mid = size.height / 2
        let current = CGFloat(meter.level(at: now))
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            // Each point is a moment of the recording, so the ink travels with the time it was spoken.
            let moment = now - span * (1 - fraction)
            let level = still ? current : CGFloat(meter.level(at: moment))
            let wander = sin(still ? Double(index) * 0.2 : moment * 4.5) * (1 + level * 2.5)
            let taper = min(1, CGFloat(min(index, count - 1 - index)) * spacing / 12)
            let half = (0.7 + level * size.height * 0.3) * taper
            let x = size.width * CGFloat(fraction)
            upper.append(CGPoint(x: x, y: mid + wander - half))
            lower.append(CGPoint(x: x, y: mid + wander + half))
        }
        var path = Path()
        path.move(to: upper[0])
        smooth(upper, into: &path)
        path.addLine(to: lower[count - 1])
        smooth(lower.reversed(), into: &path)
        path.closeSubpath()
        context.fill(path, with: .color(color))
        if let nib {
            let radius = 2.5 + current * 1.5
            let tip = CGPoint(x: size.width - radius - 1, y: mid + sin(still ? 0 : now * 4.5) * (1 + current * 2.5))
            context.fill(Path(ellipseIn: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)), with: .color(nib))
        }
    }
    /// Quadratic curves through the midpoints keep the edge smooth without overshooting.
    private static func smooth(_ points: [CGPoint], into path: inout Path) {
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
    }
}
