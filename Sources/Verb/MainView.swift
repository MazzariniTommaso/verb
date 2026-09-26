import SwiftUI
import VerbCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let t = model.lang
        Group {
            // The welcome takes the whole window until it is done.
            if let step = model.welcome {
                WelcomeView(step: step).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Sidebar()
                    Rectangle().fill(Palette.borderSubtle).frame(width: 1).accessibilityHidden(true)
                    VStack(spacing: 0) {
                        if let notice = model.notice {
                            NoticeBanner(text: t.message(notice), dismissLabel: t("Dismiss", "Chiudi")) { model.notice = nil }
                                .padding(.horizontal, Space.page).padding(.top, Space.xxxl).padding(.bottom, -Space.base)
                                .frame(maxWidth: Sizing.contentMax + Space.page * 2)
                                .transition(.opacity)
                        }
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
                .transition(.opacity)
            }
        }
        .overlayPreferenceValue(TourAnchors.self) { anchors in TourLayer(anchors: anchors) }
        .animation(.easeOut(duration: Motion.base), value: model.notice)
        .frame(minWidth: 900, minHeight: 640)
        .background(Palette.surfacePage)
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.controlOn)
        .environment(\.lang, t)
        .environment(\.locale, t.locale)
        .ignoresSafeArea()
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm + 2) {
                VerbMark().fill(Palette.accent).frame(width: 27, height: 20)
                Text("Verb").font(Typeface.display(TypeSize.title3, .medium)).tracking(-0.3).foregroundStyle(Palette.textPrimary)
            }
            .padding(.top, Space.huge - Space.xs)
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xl)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verb").accessibilityAddTraits(.isHeader)

            group(nil, [.home, .history, .notes])
            // The tour rings the group as wide as its items, not the whole sidebar.
            group(t("Words", "Parole"), [.dictionary, .snippets, .transforms]).background { Color.clear.tourAnchor(.words).padding(.horizontal, Space.sm + 2) }
            group(t("Setup", "Configurazione"), [.models, .settings])
            Spacer(minLength: Space.base)
            footer
        }
        .frame(width: Sizing.sidebar)
        .background(Palette.surfaceSunken)
    }

    private func group(_ title: String?, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).font(Typeface.text(TypeSize.caption, .semibold)).foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, Space.lg).padding(.top, Space.base).padding(.bottom, Space.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(pages) { item($0) }
        }
    }

    private func item(_ page: Page) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: Space.md) {
                Image(systemName: page.icon).font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary).frame(width: 20)
                Text(page.title(t)).font(Typeface.text(TypeSize.body, selected ? .semibold : .regular)).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if page == .history, !model.history.isEmpty {
                    Text(model.history.count.formatted(.number.locale(t.locale))).font(Typeface.text(TypeSize.caption)).monospacedDigit().foregroundStyle(Palette.textTertiary)
                        .accessibilityLabel(t.count(model.history.count, "entry", "entries", "voce", "voci"))
                }
            }
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: Sizing.controlMin - 4, alignment: .leading)
            .modifier(NavBackground(selected: selected))
            .tourAnchor(.page(page))
            .frame(minHeight: Sizing.controlMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .padding(.horizontal, Space.sm + 2)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Hairline()
            let remote = model.settings.allowRemoteProcessing
            StatusLabel(text: remote ? t("Remote processing allowed", "Elaborazione remota attiva") : t("Private. Stays on this Mac", "Privato. Resta sul Mac"),
                        symbol: remote ? "network" : "lock", tone: remote ? .warning : .neutral)
            if model.voiceListening { StatusLabel(text: t("Listening for “Hey \(model.settings.voiceOptions.spokenName)”", "In ascolto di “Ehi \(model.settings.voiceOptions.spokenName)”"), symbol: "waveform", tone: .neutral) }
            if let keys = model.settings.keyOptions.dictation { legend(keys.parts.map(t.keys), t("Hold to dictate", "Tieni premuto per dettare")) }
            Segmented(title: t("Appearance", "Aspetto"), values: Appearance.allCases, selection: $model.settings.interfaceOptions.appearance, label: { $0.title(t) }, symbol: { $0.symbol }, iconOnly: true)
        }
        .tourAnchor(.footer)
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.lg)
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
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Motion.fast), value: hovering)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
}
