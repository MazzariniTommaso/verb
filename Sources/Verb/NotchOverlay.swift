import AppKit
import SwiftUI
import VerbCore

/// Whether a view is drawn on the island under the notch, which gives it its black: the
/// overlay's own surface stays off.
private struct OnIslandKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var onIsland: Bool {
        get { self[OnIslandKey.self] }
        set { self[OnIslandKey.self] = newValue }
    }
}

/// The overlay's own surface over other apps, or none on the island.
struct OverlaySurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.onIsland) private var onIsland
    func body(content: Content) -> some View {
        if onIsland { content }
        else { content.background(Palette.surfaceOverlay, in: shape).overlay(shape.strokeBorder(Palette.borderStrong.opacity(0.45))) }
    }
}

extension NSScreen {
    /// Where the notch style sits on this screen: under its notch, or from its top edge.
    var island: IslandGeometry {
        IslandGeometry.screen(width: frame.width, left: auxiliaryTopLeftArea?.size, right: auxiliaryTopRightArea?.size,
                              safeTop: safeAreaInsets.top, menuBar: frame.maxY - visibleFrame.maxY)
    }
}

/// The notch style: a black island at the top of the screen. At rest it is the notch alone, or
/// nothing where the screen has none until the pointer comes near. Beside the notch it shows only
/// symbols, numbers and keys: what is happening on the left, how much or how on the right; and
/// when there are words to say it opens below, one rectangle with the notch inside it.
struct NotchOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: OverlayHover
    let meter: LevelMeter
    @State private var fresh = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let island = hover.island, t = model.lang
        let scene = OverlayScene.of(model.overlayFacts(hovering: hover.inside, fresh: fresh))
        Group {
            if scene.isOpen { open(scene, island) }
            else if !scene.isEmpty { closed(scene, island) }
            else { rest(island, t) }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .environment(\.onIsland, true)
        .modifier(MessageFreshness(fresh: $fresh))
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84), value: scene)
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: hover.near)
        .contentShape(Rectangle())
        // At rest, a click dictates hands-free.
        .onTapGesture { if scene.isEmpty || scene.lead == .mark { model.toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scene.isEmpty || scene.lead == .mark ? t("Verb is ready. Click to dictate.", "Verb è pronto. Clicca per dettare.") : "Verb, " + model.compactTitle(t))
    }

    /// The notch alone, drawn over it so the pointer finds it; where there is none, a small tab
    /// that shows only while the pointer is near the top.
    @ViewBuilder private func rest(_ island: IslandGeometry, _ t: Lang) -> some View {
        if let notch = island.notch {
            UnevenRoundedRectangle(bottomLeadingRadius: Self.notchRadius, bottomTrailingRadius: Self.notchRadius, style: .continuous).fill(Palette.surfaceNotch)
                .frame(width: notch.width, height: notch.height)
        } else {
            UnevenRoundedRectangle(bottomLeadingRadius: Sizing.islandTabHeight / 2, bottomTrailingRadius: Sizing.islandTabHeight / 2, style: .continuous).fill(Palette.surfaceNotch)
                .frame(width: Sizing.islandTabWidth, height: Sizing.islandTabHeight)
                .opacity(hover.near ? 1 : 0)
        }
    }

    /// Closed: a wing on each side of the notch, as tall as it. The left one moves to the right
    /// when the menus of the app in front leave no room for it.
    @ViewBuilder private func closed(_ scene: OverlayScene, _ island: IslandGeometry) -> some View {
        if let notch = island.notch {
            let leftWidth: CGFloat = scene.lead == .editing ? 64 : Sizing.islandWing
            let fits = scene.lead != nil && MenuRoom.leftFits(Double(leftWidth), free: hover.leftRoom.map(Double.init))
            let right = scene.trail != .none || (scene.lead != nil && !fits)
            IslandRow {
                Group {
                    if fits, let lead = scene.lead { LeadSymbol(lead: lead, meter: meter).frame(minWidth: leftWidth) }
                    else { Color.clear.frame(width: 0) }
                }
                .frame(height: notch.height)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: Radius.lg, style: .continuous).fill(Palette.surfaceNotch))
                UnevenRoundedRectangle(bottomLeadingRadius: fits ? 0 : Self.notchRadius, bottomTrailingRadius: right ? 0 : Self.notchRadius, style: .continuous)
                    .fill(Palette.surfaceNotch).frame(width: notch.width, height: notch.height)
                HStack(spacing: Space.sm) {
                    if !fits, let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
                    TrailContent(trail: scene.trail)
                }
                .padding(.leading, right ? 12 : 0).padding(.trailing, right ? (scene.trail == .none || scene.trail == .time ? 14 : 6) : 0)
                .frame(minWidth: right ? Sizing.islandWing : 0)
                .frame(height: notch.height)
                .background(UnevenRoundedRectangle(bottomTrailingRadius: Radius.lg, style: .continuous).fill(Palette.surfaceNotch))
            }
        } else {
            HStack(spacing: Space.md) {
                if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
                TrailContent(trail: scene.trail)
            }
            .padding(.leading, 12).padding(.trailing, scene.trail == .none || scene.trail == .time || scene.trail == .key ? 12 : 4)
            .frame(height: 28)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).fill(Palette.surfaceNotch))
        }
    }

    /// Open: one rectangle from the top edge, wider than the notch, over the menu bar while it
    /// lasts. Beside the notch the same symbols as when closed; the words below.
    private func open(_ scene: OverlayScene, _ island: IslandGeometry) -> some View {
        let box = scene.body == .paste || scene.body == .answer
        return VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                if let lead = scene.lead { LeadSymbol(lead: lead, meter: meter) }
                Spacer(minLength: 0)
                TrailContent(trail: scene.trail)
            }
            .padding(.leading, 20).padding(.trailing, scene.trail == .none || scene.trail == .time ? 20 : 8)
            .frame(height: island.hasNotch ? island.band : 32)
            OverlayBody(body_: scene.body)
                .padding(.horizontal, 20).padding(.top, Space.xs).padding(.bottom, Space.base)
                .frame(maxWidth: .infinity, maxHeight: box ? .infinity : nil, alignment: .topLeading)
        }
        .frame(width: Sizing.overlayOpenWidth, height: box ? Sizing.overlayBoxHeight : nil, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: Radius.xl, bottomTrailingRadius: Radius.xl, style: .continuous).fill(Palette.surfaceNotch))
    }

    /// The bottom corners of the Mac's notch, drawn the same so nothing shows past them.
    static let notchRadius: CGFloat = 10
}

/// The wings and the notch between them: the notch stays in the middle whatever each wing
/// holds, so the island never slides sideways as it changes.
struct IslandRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let side = max(sizes[0].width, sizes[2].width)
        return CGSize(width: side * 2 + sizes[1].width, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let side = max(sizes[0].width, sizes[2].width)
        subviews[0].place(at: CGPoint(x: bounds.minX + side - sizes[0].width, y: bounds.minY), proposal: ProposedViewSize(sizes[0]))
        subviews[1].place(at: CGPoint(x: bounds.minX + side, y: bounds.minY), proposal: ProposedViewSize(sizes[1]))
        subviews[2].place(at: CGPoint(x: bounds.minX + side + sizes[1].width, y: bounds.minY), proposal: ProposedViewSize(sizes[2]))
    }
}
