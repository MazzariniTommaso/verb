import SwiftUI
import VerbCore

/// How the page lays itself out in the room beside the sidebar: its size, margins and gutter.
private struct PageLayoutKey: EnvironmentKey { static let defaultValue = PageLayout(room: 1080 - Sizing.sidebar - 1, spec: MainView.spec) }
extension EnvironmentValues {
    var pageLayout: PageLayout {
        get { self[PageLayoutKey.self] }
        set { self[PageLayoutKey.self] = newValue }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    /// Verb's page sizes: the room where each starts, margins of 32, 40, 48 and 56, gutters of
    /// 16, 24, 24 and 32.
    static let spec = PageLayout.Spec(mediumFrom: Sizing.pageMediumFrom, largeFrom: Sizing.pageLargeFrom, extraLargeFrom: Sizing.pageExtraLargeFrom,
                                      margins: [Space.xxl, Space.xxxl, Space.page, Space.huge], gutters: [Space.base, Space.xl, Space.xl, Space.xxl])
    var body: some View {
        // The room is read in the same pass that lays the window out, so no frame shows the
        // layout of another width. The tour stays outside, where the page's anchors reach it whole.
        GeometryReader { proxy in
            let icons = model.settings.sidebarCollapsed
            let sidebar = icons ? model.windowButtons.railWidth : Sizing.sidebar
            let room = model.welcome == nil ? proxy.size.width - sidebar - 1 : proxy.size.width
            content(icons: icons, sidebar: sidebar)
                .environment(\.pageLayout, PageLayout(room: room, spec: Self.spec))
                .ignoresSafeArea()
        }
        .overlayPreferenceValue(TourAnchors.self) { anchors in TourLayer(anchors: anchors) }
        .frame(minWidth: Sizing.windowMinWidth, minHeight: Sizing.windowMinHeight)
        .background(Palette.surfacePage)
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.controlOn)
        .environment(\.lang, model.lang)
        .environment(\.locale, model.lang.locale)
        .ignoresSafeArea()
    }

    private func content(icons: Bool, sidebar: CGFloat) -> some View {
        let t = model.lang
        return Group {
            // The welcome takes the whole window until it is done.
            if let step = model.welcome {
                WelcomeView(step: step, tried: model.welcomeTriedBefore).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Sidebar(icons: icons).frame(width: sidebar)
                    Rectangle().fill(Palette.borderSubtle).frame(width: 1).accessibilityHidden(true)
                    VStack(spacing: 0) {
                        if let notice = model.notice { NoticeRow(text: t.message(notice), dismissLabel: t("Dismiss", "Chiudi")) { model.dismissNotice() } }
                        Group {
                            switch model.page {
                            case .home: HomeView()
                            case .history: HistoryView()
                            case .notes: NotesPage()
                            case .dictionary: DictionaryView()
                            case .snippets: SnippetsView()
                            case .transforms: TransformsView()
                            case .models: ModelsView()
                            case .settings: SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Palette.surfacePage)
                }
                // Under the tour's shade, VoiceOver hears the tour alone.
                .accessibilityHidden(model.tourStop != nil)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Motion.base), value: model.notice)
    }
}

/// A notice over the page, in the page's column.
private struct NoticeRow: View {
    let text: String
    let dismissLabel: String
    let dismiss: () -> Void
    @Environment(\.pageLayout) private var layout
    var body: some View {
        NoticeBanner(text: text, dismissLabel: dismissLabel, onDismiss: dismiss)
            .frame(maxWidth: Sizing.contentMax, alignment: .leading)
            .padding(.horizontal, layout.margin).padding(.top, Sizing.pageTop).padding(.bottom, -Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }
}

/// The pages, in three groups. Whole, each with its icon and name; or, when you ask, the icons
/// alone in a rail as wide as the window's buttons, standing on their middle. Rows and headings
/// start 20 pt in, and the first line is 48 pt from the top, as on every page.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    /// The icons alone, each with its name in a tooltip and for VoiceOver.
    var icons = false
    var body: some View {
        VStack(alignment: icons ? .center : .leading, spacing: 0) {
            HStack(spacing: Space.sm + 2) {
                HStack(spacing: Space.sm + 2) {
                    VerbMark().fill(Palette.accent).frame(width: 27, height: 20)
                    if !icons { Text("Verb").font(Typeface.display(TypeSize.title3, .medium)).tracking(-0.3).foregroundStyle(Palette.textPrimary) }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Verb").accessibilityAddTraits(.isHeader)
                if !icons { Spacer(minLength: 0); sidebarButton }
            }
            .frame(height: 28)
            .padding(.top, Sizing.pageTop - 4)
            .padding(.leading, icons ? 0 : Space.lg)
            .padding(.trailing, icons ? 0 : Space.sm)
            .padding(.bottom, Space.lg)

            // In a short window the pages scroll above the footer rather than push it off.
            ScrollView { pages }.scrollIndicators(.never).scrollBounceBehavior(.basedOnSize).padding(.bottom, Space.base)
            footer
        }
        .frame(maxWidth: .infinity, alignment: icons ? .center : .leading)
        .background(Palette.surfaceSunken)
    }

    private var pages: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(nil, [.home, .history, .notes])
            // The tour rings the group as wide as its items, not the whole sidebar.
            group(t("Words", "Parole"), [.dictionary, .snippets, .transforms]).background { Color.clear.tourAnchor(.words).padding(.horizontal, Space.sm) }
            group(t("Setup", "Configurazione"), [.models, .settings])
        }
    }

    private func group(_ title: String?, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                // With the icons alone, a rule as wide as an icon's highlight stands for the
                // group's name; VoiceOver still hears it.
                if icons {
                    Rectangle().fill(Palette.borderSubtle).frame(height: 1).padding(.horizontal, Space.base).padding(.vertical, Space.md)
                        .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isHeader)
                } else {
                    Text(title).font(Typeface.text(TypeSize.caption, .semibold)).foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, Space.lg).padding(.top, Space.base).padding(.bottom, Space.xs)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) { ForEach(pages) { item($0) } }
        }
    }

    private func item(_ page: Page) -> some View {
        let selected = model.page == page
        let count = page == .history && !model.history.isEmpty ? model.history.count : nil
        return Button { model.page = page } label: {
            HStack(spacing: Space.md) {
                Image(systemName: page.icon).font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary).frame(width: 20)
                if !icons {
                    Text(page.title(t)).font(Typeface.text(TypeSize.body, selected ? .semibold : .regular)).foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    if let count {
                        Text(count.formatted(.number.locale(t.locale))).font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            // A Mac source list: rows 32 pt tall and 36 apart, the whole row answering a click.
            // The highlight 8 pt in from the edge, the icon at 20, the name at 52.
            .padding(.horizontal, icons ? 0 : Space.md)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: icons ? .center : .leading)
            .modifier(NavBackground(selected: selected))
            .tourAnchor(.page(page))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .padding(.horizontal, Space.sm)
        .help(icons ? page.title(t) : "")
        .accessibilityLabel([page.title(t), count.map { t.count($0, "entry", "entries", "voce", "voci") }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var footer: some View {
        VStack(alignment: icons ? .center : .leading, spacing: Space.md) {
            Hairline()
            let remote = model.settings.allowRemoteProcessing
            let privacy = remote ? t("Remote processing allowed", "Elaborazione remota attiva") : t("Private. Stays on this Mac", "Privato. Resta sul Mac")
            let listening = t("Listening for “Hey \(model.settings.voiceOptions.spokenName)”", "In ascolto di “Ehi \(model.settings.voiceOptions.spokenName)”")
            if icons {
                // The same facts as symbols, their words in a tooltip and for VoiceOver.
                if model.voiceListening { Image(systemName: "waveform").font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textSecondary).help(listening).accessibilityLabel(listening) }
                Image(systemName: remote ? "network" : "lock").font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(remote ? Palette.warning : Palette.textSecondary)
                    .help(privacy).accessibilityLabel(privacy)
                sidebarButton
            } else {
                StatusLabel(text: privacy, symbol: remote ? "network" : "lock", tone: remote ? .warning : .neutral)
                if model.voiceListening { StatusLabel(text: listening, symbol: "waveform", tone: .neutral) }
                if let keys = model.settings.keyOptions.dictation { legend(keys.parts.map(t.keys), t("Hold to dictate", "Tieni premuto per dettare")) }
            }
        }
        .tourAnchor(.footer)
        .padding(.horizontal, icons ? Space.sm : Space.lg)
        .padding(.bottom, icons ? Space.sm : Space.lg)
    }

    /// The icons alone or the whole sidebar, as with ⌃⌘S.
    private var sidebarButton: some View {
        let label = icons ? t("Show the whole sidebar", "Mostra tutta la barra laterale") : t("Show only the icons", "Mostra solo le icone")
        return Button { model.settings.sidebarCollapsed.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
                .frame(width: 32, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .help(label + " (⌃⌘S)").accessibilityLabel(label)
    }
}

private func legend(_ keys: [String], _ meaning: String) -> some View {
    HStack(spacing: Space.sm) {
        HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0) } }
        Text(meaning).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.85)
    }
    .accessibilityElement(children: .combine)
}

/// The selected page is a sheet lifted from the sidebar; the others darken slightly under the pointer.
private struct NavBackground: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Palette.surfaceRaised : (hovering ? Palette.fillHover : .clear))
                    .shadow(color: selected ? Palette.shadow.opacity(0.35) : .clear, radius: 2, y: 1)
            }
            .overlay { if selected { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.borderSubtle) } }
            .onPointerOver { hovering = $0 }
            .animation(.easeOut(duration: Motion.fast), value: hovering)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
}
