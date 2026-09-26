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

/// A sheet of card stock laid on the page. `lifted` is kept for the one thing a page leads with.
struct Card<Content: View>: View {
    var padding: CGFloat = Space.xl
    var lifted = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.borderSubtle).frame(height: 1).accessibilityHidden(true) }
}

/// Scrolls a page and keeps its column at a readable width.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) { content }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.xxxl + Space.xs)
                .padding(.bottom, Space.huge)
                .frame(maxWidth: Sizing.contentMax + Space.page * 2, alignment: .leading)
                .frame(maxWidth: .infinity)
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
        // Title and buttons side by side while both fit; in a narrow window the buttons go under
        // the title, whole, rather than lose their words.
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
            if let detail {
                Text(detail).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.ui))
                    .frame(maxWidth: 540, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
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
    @State private var hovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.md, style: .continuous) }
    var body: some View {
        configuration.label
            .font(Typeface.text(compact ? TypeSize.footnote : TypeSize.body, kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .underline(kind == .link && hovering)
            .padding(.horizontal, kind == .link ? 0 : (compact ? Space.md : Space.base))
            .frame(minHeight: compact ? 28 : 34)
            .background(fill, in: shape)
            .overlay { if let border { shape.strokeBorder(border) } }
            // The visible button stays trim; the hit area keeps the 44 pt minimum.
            .frame(minHeight: Sizing.controlMin)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && kind != .link ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: Motion.fast), value: hovering)
            .animation(.easeOut(duration: Motion.fast), value: configuration.isPressed)
            .onHover { hovering = $0 && enabled }
    }
    private var foreground: Color {
        switch kind {
        case .primary: return Palette.textOnInverse
        case .secondary, .quiet: return Palette.textPrimary
        case .danger, .dangerQuiet: return Palette.danger
        case .link: return configuration.isPressed ? Palette.accentStrong : Palette.accent
        }
    }
    private var fill: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return hovering || pressed ? Palette.surfaceInverseHover : Palette.surfaceInverse
        case .secondary: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : Palette.surfaceRaised)
        case .quiet: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : .clear)
        case .danger, .dangerQuiet: return pressed ? Palette.fillPressed : (hovering ? Palette.fillHover : .clear)
        case .link: return .clear
        }
    }
    private var border: Color? {
        switch kind {
        case .secondary: return Palette.borderSubtle
        case .danger: return Palette.danger.opacity(0.4)
        default: return nil
        }
    }
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
        HStack(alignment: .center, spacing: Space.base) {
            RowLabel(title: title, detail: detail)
            control
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
                Capsule().fill(configuration.isOn ? Palette.controlOn : Palette.fillPressed)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Palette.borderStrong.opacity(0.55)))
                Circle().fill(configuration.isOn ? Palette.controlKnobOn : Palette.controlKnob).shadow(color: Palette.shadow, radius: 1.5, y: 1).padding(2.5)
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
        .onHover { hovering = $0 }
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
        .onHover { hovering = $0 }
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
    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
            Text(title).font(Typeface.display(TypeSize.title3)).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.center)
            Text(detail).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(Space.xl)
        .accessibilityElement(children: .combine)
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

private struct FieldFrame: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(focused ? Palette.controlOn : Palette.borderStrong, lineWidth: focused ? 2 : 1))
            .animation(.easeOut(duration: Motion.fast), value: focused)
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
                if secure { SecureField(label, text: $text, prompt: Text(prompt)) } else { TextField(label, text: $text, prompt: Text(prompt)) }
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
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary).accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Palette.textTertiary)).textFieldStyle(.plain).font(Typeface.text(TypeSize.body)).focused($focused)
            if !text.isEmpty { IconButton(symbol: "xmark.circle.fill", label: clearLabel) { text = "" }.foregroundStyle(Palette.textTertiary) }
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: 40)
        .modifier(FieldFrame(focused: focused))
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
