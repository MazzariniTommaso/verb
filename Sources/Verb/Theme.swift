import SwiftUI
import VerbCore

// Components for the paper-and-ink interface. Every value comes from DesignTokens.swift,
// which is generated from Design/tokens.json; nothing here picks its own colour or size.

enum Typeface {
    /// New York, for titles and for the words themselves.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    /// SF Pro, for every control and label.
    static func text(_ size: CGFloat = TypeSize.body, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// SF Mono, for commands, paths and identifiers only.
    static func mono(_ size: CGFloat = TypeSize.footnote) -> Font { .system(size: size, design: .monospaced) }
}

/// The extra line spacing that gives a font size the leading named in the tokens.
func leading(_ size: CGFloat, _ multiplier: CGFloat) -> CGFloat { max(0, size * multiplier - size * 1.2) }

func durationLabel(_ seconds: Double) -> String { let seconds = max(0, Int(seconds)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }

// MARK: - Surfaces

/// Cards side by side take the height of the tallest.
private struct CardsMatchKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var cardsMatchHeight: Bool {
        get { self[CardsMatchKey.self] }
        set { self[CardsMatchKey.self] = newValue }
    }
}

/// A sheet of card stock laid on the page. `lifted` is kept for the one thing a page leads with.
struct Card<Content: View>: View {
    var padding: CGFloat = Space.xl
    var lifted = false
    @ViewBuilder var content: Content
    @Environment(\.cardsMatchHeight) private var matchHeight
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: matchHeight ? .infinity : nil, alignment: .topLeading)
            // The sheet casts the shadow, not every word and button on it.
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Palette.surfaceRaised)
                .shadow(color: lifted ? Palette.shadow.opacity(0.45) : .clear, radius: lifted ? 18 : 0, y: lifted ? 8 : 0))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
    }
}

/// Rows on one sheet, separated by hairlines. Row backgrounds are clipped to the sheet.
struct RowList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
            // One stop for the keyboard as a whole, so a long list is quick to pass over.
            .focusSection()
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.borderSubtle).frame(height: 1).accessibilityHidden(true) }
}

/// Scrolls a page. Its column starts at the margin, by the sidebar, and stops at `cap`: what is
/// left of a wide window goes to the trailing side, so the page's edge never moves as the window
/// grows, nor from one page to the next.
struct PageScroll<Content: View>: View {
    var cap: CGFloat = Sizing.contentMax
    @ViewBuilder var content: Content
    @Environment(\.pageLayout) private var layout
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) { content }
                .frame(maxWidth: cap, alignment: .leading)
                .padding(.horizontal, layout.margin)
                .padding(.top, Sizing.pageTop)
                .padding(.bottom, Space.huge)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// A paragraph's measure, about 90 characters, however wide its card.
    func measure() -> some View { frame(maxWidth: Sizing.columnParagraph, alignment: .leading) }
}

/// Views side by side, each as wide as the widest needs: their ideal width says so, so a
/// `ViewThatFits` moves on when one of them would lose its words.
struct EqualWidths: Layout {
    var spacing: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let needed = (ideal.map(\.width).max() ?? 0) * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        return CGSize(width: proposal.width ?? needed, height: ideal.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

// MARK: - Headings

/// A small red heading, as rubricators wrote them in manuscripts. It always carries real information.
struct Rubric: View {
    let text: String
    var body: some View {
        Text(text).font(Typeface.text(TypeSize.caption, .semibold)).tracking(Tracking.rubric).textCase(.uppercase).foregroundStyle(Palette.accent).lineLimit(1)
    }
}

/// A quiet heading in graphite for groups inside a page, such as the days in History.
struct Overline: View {
    let text: String
    var body: some View {
        Text(text).font(Typeface.text(TypeSize.caption, .semibold)).tracking(Tracking.rubric).textCase(.uppercase).foregroundStyle(Palette.textSecondary).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

extension VerticalAlignment {
    private enum TitleLine: AlignmentID { static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] } }
    /// The middle of a page title: the header's button stays level with it however the text below wraps.
    static let titleLine = VerticalAlignment(TitleLine.self)
}

struct PageHeader<Accessory: View>: View {
    let rubric: String?
    let title: String
    let detail: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // Title and buttons side by side while both fit; in a narrow window the buttons go under
            // the title, whole, rather than lose their words. The description runs under both, at
            // its own width, so the buttons never squeeze it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .titleLine, spacing: Space.xl) {
                    heading.frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                    accessory.fixedSize().alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
                }
                VStack(alignment: .leading, spacing: Space.lg) {
                    heading
                    accessory.fixedSize()
                }
            }
            if let detail {
                Text(detail).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.ui))
                    .frame(maxWidth: 540, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // The rubric takes no width from the title's column: in a narrow window it runs on
            // above the buttons rather than lose its last words to them. A page without one keeps
            // its line, so every title sits at the same height.
            Rubric(text: rubric ?? " ").fixedSize().frame(width: 0, alignment: .leading).opacity(rubric == nil ? 0 : 1).accessibilityHidden(rubric == nil)
            Text(title).font(Typeface.display(TypeSize.title1)).tracking(Tracking.display).foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
        }
        // The tour leaves the title of the page it shows uncovered; its buttons stay under the shade.
        .tourAnchor(.header)
    }
}
extension PageHeader where Accessory == EmptyView {
    init(rubric: String?, title: String, detail: String?) { self.init(rubric: rubric, title: title, detail: detail) { EmptyView() } }
}

/// A heading inside a page. The numeral, when present, is set in red italic.
struct SectionHeading: View {
    var numeral: String? = nil
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            if let numeral { Text(numeral).font(Typeface.display(TypeSize.title2).italic()).foregroundStyle(Palette.accent) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typeface.display(TypeSize.title3, .medium)).foregroundStyle(Palette.textPrimary)
                if let detail {
                    Text(detail).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

struct VerbButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger, dangerQuiet, link }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View { VerbButtonBody(configuration: configuration, kind: kind, compact: compact) }
}

private struct VerbButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: VerbButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.md, style: .continuous) }
    var body: some View {
        configuration.label
            .font(Typeface.text(compact ? TypeSize.footnote : TypeSize.body, kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .underline(kind == .link && hovering)
            .padding(.horizontal, kind == .link ? 0 : (compact ? Space.md : Space.base))
            .frame(minHeight: compact ? 26 : 30)
            .background(fill, in: shape)
            .overlay { if let border { shape.strokeBorder(border) } }
            // The keyboard focus ring follows the button you see, not its larger hit area.
            .contentShape(.focusEffect, shape)
            // The visible button stays trim; the hit area keeps the 44 pt minimum.
            .frame(minHeight: Sizing.controlMin)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && kind != .link && !reduceMotion ? 0.98 : 1)
            // A primary button that can't be used yet is drawn as a quiet outline, not as faded ink.
            .opacity(enabled || kind == .primary ? 1 : 0.4)
            .animation(.easeOut(duration: Motion.fast), value: hovering)
            .animation(.easeOut(duration: Motion.fast), value: configuration.isPressed)
            .onPointerOver { hovering = $0 && enabled }
    }
    private var foreground: Color {
        switch kind {
        case .primary: return enabled ? Palette.textOnInverse : Palette.textTertiary
        case .secondary, .quiet: return Palette.textPrimary
        case .danger, .dangerQuiet: return Palette.danger
        case .link: return configuration.isPressed ? Palette.accentStrong : Palette.accent
        }
    }
    private var fill: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return !enabled ? Palette.surfaceRaised : hovering || pressed ? Palette.surfaceInverseHover : Palette.surfaceInverse
        case .secondary: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : Palette.surfaceRaised)
        case .quiet: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : .clear)
        case .danger, .dangerQuiet: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : .clear)
        case .link: return .clear
        }
    }
    private var border: Color? {
        switch kind {
        case .primary: return enabled ? nil : Palette.borderSubtle
        case .secondary: return Palette.borderSubtle
        case .danger: return Palette.danger.opacity(contrast == .increased ? 1 : 0.4)
        default: return nil
        }
    }
}

/// Whether the pointer is over a view, from an AppKit tracking area as large as the view.
/// SwiftUI's own hover is lost over parts of some controls: a button lit only while the pointer
/// crossed its edge, and not when it rested in the middle.
private struct PointerOver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { let view = TrackingView(); view.changed = changed; return view }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var inside = false
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            // Appearing under a still pointer counts as being entered.
            if let window { set(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
        }
        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { set(false) } }
        // Clicks go to the control on top, never here.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value; changed(value)
        }
    }
}
extension View {
    /// Says when the pointer comes over the view and leaves it, anywhere in its frame.
    func onPointerOver(_ changed: @escaping (Bool) -> Void) -> some View { background(PointerOver(changed: changed)) }
}

/// For rows and cards that are buttons: dims on press and when disabled, nothing else.
struct PlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PlainPressBody(configuration: configuration) }
}
private struct PlainPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View { configuration.label.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4) }
}

/// An icon-only button with a label for VoiceOver and a tooltip.
struct IconButton: View {
    let symbol: String
    let label: String
    var tone: VerbButtonStyle.Kind = .quiet
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18) }
            .buttonStyle(VerbButtonStyle(kind: tone == .danger ? .dangerQuiet : .quiet, compact: true))
            .help(label).accessibilityLabel(label)
    }
}

// MARK: - Rows and controls

struct RowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typeface.text(TypeSize.body, .medium)).foregroundStyle(Palette.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label on the left and any control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        // Side by side while the control keeps its words beside a label of fair width; under the
        // label otherwise, at its leading edge.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.base) {
                // Measured at a fair width, so a long description wraps rather than push the control under.
                RowLabel(title: title, detail: detail).frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                control
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                RowLabel(title: title, detail: detail)
                control
            }
        }
        .padding(.vertical, Space.sm)
        .frame(minHeight: Sizing.controlMin)
    }
}

/// A setting that is on or off, with the native switch on the right. Clicking the label toggles it too.
struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(alignment: .center, spacing: Space.base) {
            RowLabel(title: title, detail: detail).contentShape(Rectangle()).onTapGesture { if enabled { isOn.toggle() } }.accessibilityHidden(true)
            Toggle(title, isOn: $isOn).toggleStyle(InkSwitchStyle()).accessibilityHint(detail ?? "")
        }
        .padding(.vertical, Space.sm)
        .frame(minHeight: Sizing.controlMin)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The switch, drawn in ink (ember at night) so it matches the page in every window state.
/// It stays a real Toggle: VoiceOver reads it as a switch and Space flips it when focused.
struct InkSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { InkSwitch(configuration: configuration) }
}
private struct InkSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                // Off, the track has a full border and the knob a ring of its own, so the state reads
                // without the colour of on.
                Capsule().fill(configuration.isOn ? Palette.controlOn : Palette.fillPressed)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Palette.borderStrong, lineWidth: 1.5))
                Circle().fill(configuration.isOn ? Palette.controlKnobOn : Palette.controlKnob)
                    .overlay(Circle().strokeBorder(configuration.isOn ? Color.clear : Palette.borderStrong.opacity(0.7), lineWidth: 1))
                    .shadow(color: Palette.shadow, radius: 1.5, y: 1).padding(3)
            }
            .frame(width: 40, height: 24)
            .frame(minWidth: Sizing.controlMin, minHeight: Sizing.controlMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: configuration.isOn)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A row that opens its editor. Removing lives in the editor, behind a confirmation, never one click away.
struct EditableRow<Content: View>: View {
    let hint: String
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.base) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(hovering ? Palette.fillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onPointerOver { hovering = $0 }
        .accessibilityHint(hint)
    }
}

struct RadioMark: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Palette.controlOn : Palette.borderStrong, lineWidth: 1.5)
            if selected { Circle().fill(Palette.controlOn).padding(4) }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Mutually exclusive options shown as cards, each with a line of explanation.
struct ChoiceCards<Value: Hashable>: View {
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var detail: ((Value) -> String)? = nil
    var columns = 2
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm, alignment: .top), count: columns), spacing: Space.sm) {
            ForEach(values, id: \.self) { value in
                ChoiceCard(title: label(value), detail: detail?(value), selected: selection == value) { selection = value }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

private struct ChoiceCard: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.md, style: .continuous) }
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.md) {
                RadioMark(selected: selected).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Typeface.text(TypeSize.body, selected ? .semibold : .medium)).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: Sizing.optionMin, alignment: .topLeading)
            .background(selected || hovering ? Palette.fillHover : Color.clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Palette.controlOn : Palette.borderSubtle, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onPointerOver { hovering = $0 }
        .animation(.easeOut(duration: Motion.fast), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A compact choice between two or three values, drawn as a raised sheet on a sunken track.
struct Segmented<Value: Hashable>: View {
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var symbol: ((Value) -> String)? = nil
    var iconOnly = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let selected = value == selection
                Button { selection = value } label: {
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol(value)).font(.system(size: 12, weight: selected ? .semibold : .regular)) }
                        if !iconOnly { Text(label(value)).font(Typeface.text(TypeSize.footnote, selected ? .semibold : .medium)).lineLimit(1) }
                    }
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .padding(.horizontal, iconOnly ? 0 : Space.md)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(selected ? Palette.surfaceSelected : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    // The choice has an edge in the colour of on, so it shows in the dark and with low contrast too.
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(selected ? Palette.controlOn.opacity(0.85) : .clear, lineWidth: 1.25))
                    .shadow(color: selected ? Palette.shadow.opacity(0.4) : .clear, radius: 1.5, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help(label(value))
                .accessibilityLabel(label(value))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.fillPressed, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .animation(.easeOut(duration: Motion.fast), value: selection)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

// MARK: - Small pieces

/// A key on the keyboard, for shortcuts.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(Typeface.text(TypeSize.caption, .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).strokeBorder(Palette.borderStrong.opacity(0.55)))
            .shadow(color: Palette.shadow.opacity(0.5), radius: 0, y: 1)
    }
}

/// Status is never colour alone: every tone has an icon and words.
struct StatusLabel: View {
    enum Tone { case neutral, success, warning, danger, accent }
    let text: String
    let symbol: String
    var tone: Tone = .neutral
    var body: some View {
        Label { Text(text).lineLimit(2) } icon: { Image(systemName: symbol) }
            .font(Typeface.text(TypeSize.footnote, .medium))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch tone {
        case .neutral: return Palette.textSecondary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .danger: return Palette.danger
        case .accent: return Palette.accent
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    /// The way out of the empty state, when there is one: add the first, restore, choose.
    var action: (title: String, perform: () -> Void)? = nil
    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
            Text(title).font(Typeface.display(TypeSize.title3)).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.center)
            Text(detail).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.title, action: action.perform).buttonStyle(VerbButtonStyle(kind: .secondary)).padding(.top, Space.xs) }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(Space.xl)
        .accessibilityElement(children: .contain)
    }
}

struct NoticeBanner: View {
    let text: String
    let dismissLabel: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.warning).padding(.top, 1).accessibilityHidden(true)
            Text(text).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textPrimary).lineSpacing(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            IconButton(symbol: "xmark", label: dismissLabel, action: onDismiss).padding(.vertical, -Space.md)
        }
        .padding(.horizontal, Space.base).padding(.vertical, Space.md)
        .background(Palette.warningTint, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.warning.opacity(0.35)))
    }
}

// MARK: - Fields

struct FieldLabel: View {
    let text: String
    var body: some View { Text(text).font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textSecondary) }
}

/// A field's edge: a hairline of the 3:1 colour at rest, so an empty field is not the boldest
/// thing on the page, and 2 pt of ink when it has the keys. `sunken` sets it into its card
/// with no edge at rest, as the search in the notes.
private struct FieldFrame: ViewModifier {
    let focused: Bool
    var sunken = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        let lit = hovering && !focused
        content
            // Under the pointer the field darkens a little and its edge firms up, as buttons do.
            .background { ZStack { shape.fill(sunken ? Palette.surfaceSunken : Palette.surfaceRaised); shape.fill(lit ? Palette.fillHover : .clear) } }
            .overlay(shape.strokeBorder(focused ? Palette.controlOn : (lit ? Palette.textSecondary : (sunken ? .clear : Palette.borderStrong)), lineWidth: focused ? 2 : (lit ? 1 : 0.75)))
            .onPointerOver { hovering = $0 }
            .animation(.easeOut(duration: Motion.fast), value: focused)
            .animation(.easeOut(duration: Motion.fast), value: hovering)
    }
}

/// A text field with its label above it. Placeholders never stand in for labels.
struct VerbField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var mono = false
    var showsLabel = true
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel { FieldLabel(text: label) }
            Group {
                // Placeholders in the tertiary ink, legible where they say what an empty field means.
                if secure { SecureField(label, text: $text, prompt: Text(prompt).foregroundColor(Palette.textTertiary)) } else { TextField(label, text: $text, prompt: Text(prompt).foregroundColor(Palette.textTertiary)) }
            }
            .textFieldStyle(.plain)
            .font(mono ? Typeface.mono(TypeSize.body) : Typeface.text(TypeSize.body))
            .foregroundStyle(Palette.textPrimary)
            .focused($focused)
            .padding(.horizontal, Space.md)
            .frame(minHeight: 36)
            .modifier(FieldFrame(focused: focused))
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String
    /// Set into a card, as in the notes, rather than standing on the page.
    var sunken = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Palette.textTertiary)).textFieldStyle(.plain).font(Typeface.text(TypeSize.body)).focused($focused)
            if !text.isEmpty { IconButton(symbol: "xmark.circle.fill", label: clearLabel) { text = "" }.foregroundStyle(Palette.textTertiary) }
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: sunken ? 34 : 40)
        .modifier(FieldFrame(focused: focused, sunken: sunken))
        // As long as a search needs, not as long as the page.
        .frame(maxWidth: Sizing.searchWidth, alignment: .leading)
    }
}

struct VerbEditor: View {
    @Binding var text: String
    var serif = false
    var minHeight: CGFloat = 160
    /// What VoiceOver calls the field.
    var label = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .accessibilityLabel(label)
            .font(serif ? Typeface.display(TypeSize.reading) : Typeface.text(TypeSize.body))
            .lineSpacing(serif ? leading(TypeSize.reading, Leading.reading) : leading(TypeSize.body, Leading.ui))
            .foregroundStyle(Palette.textPrimary)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(Space.sm)
            .frame(minHeight: minHeight)
            .modifier(FieldFrame(focused: focused))
    }
}

/// A choice from a list, drawn like Verb's own fields instead of the system's pop-up button,
/// which ignores the palette: the chosen value and a chevron on paper, opening the system's
/// menu with the choice ticked.
struct VerbPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.isEnabled) private var enabled
    private var current: String { options.first { $0.value == selection }?.label ?? "" }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].label).tag(options[index].value) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: Space.sm) {
                Text(current).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, Space.md).frame(height: 30)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderStrong.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(title).accessibilityValue(current)
    }
}
