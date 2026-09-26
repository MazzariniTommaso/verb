import SwiftUI
import VerbCore

// The tour of the window: a stop for each part of the sidebar, then what stays at the bottom of
// it and the menu bar. The rest of the window steps back under a shade that leaves uncovered
// the sidebar item, ringed in red, and the header of the page it opens behind; a card in the
// corner says what the page is for. It follows the welcome when asked, then without the menu
// bar that the welcome's last page has just shown, and opens again from the Help menu and Settings.

/// What a stop points at in the window.
enum TourTarget: Hashable { case page(Page), words, header, footer }

/// Where each target is drawn, so the shade can leave it uncovered.
struct TourAnchors: PreferenceKey {
    static var defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}
extension View {
    /// Marks the view as a place the tour can point at.
    func tourAnchor(_ target: TourTarget) -> some View { anchorPreference(key: TourAnchors.self, value: .bounds) { [target: $0] } }
}

struct TourStop: Equatable {
    /// What the ring goes around; nil for the menu bar, which is outside the window.
    let target: TourTarget?
    /// The page open behind the stop, whose header stays uncovered too.
    let page: Page
    var showsHeader = true
    static let all: [TourStop] = [
        TourStop(target: .page(.home), page: .home), TourStop(target: .page(.history), page: .history), TourStop(target: .page(.notes), page: .notes),
        TourStop(target: .words, page: .dictionary), TourStop(target: .page(.models), page: .models), TourStop(target: .page(.settings), page: .settings),
        TourStop(target: .footer, page: .home, showsHeader: false), TourStop(target: nil, page: .home, showsHeader: false),
    ]
}

extension AppModel {
    /// Right after the welcome, the tour leaves out the menu bar: Ready has just shown it.
    func startTour(afterWelcome: Bool = false) {
        welcome = nil
        tourStops = afterWelcome ? TourStop.all.filter { $0.target != nil } : TourStop.all
        moveTour(to: 0)
        showWindow?()
    }
    /// Past the last stop, the tour ends.
    func moveTour(to index: Int) {
        guard tourStops.indices.contains(index) else { endTour(); return }
        tourStop = index
        page = tourStops[index].page
    }
    func endTour() {
        tourStop = nil
        page = .home
    }
}

/// The shade, the ring around what the stop points at, and the card.
struct TourLayer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let anchors: [TourTarget: Anchor<CGRect>]
    @State private var cardHeight: CGFloat = 220
    /// What each stop found to point at, for the welcome check.
    static var reached: [Int: CGRect?] = [:]
    private struct Reached: Equatable { let index: Int; let rect: CGRect? }
    var body: some View {
        if let index = model.tourStop, model.welcome == nil, model.tourStops.indices.contains(index) {
            GeometryReader { proxy in
                let stop = model.tourStops[index]
                let found = stop.target.flatMap { anchors[$0] }.map { proxy[$0].insetBy(dx: -4, dy: -4) }
                let header = stop.showsHeader ? anchors[.header].map { proxy[$0].insetBy(dx: -Space.md, dy: -Space.md) } : nil
                // An opening that isn't needed closes where it is, or in the middle of the window.
                let hole = found ?? CGRect(x: proxy.size.width / 2, y: proxy.size.height / 2, width: 0, height: 0)
                let page = header ?? CGRect(x: hole.midX, y: hole.midY, width: 0, height: 0)
                let width: CGFloat = stop.target == nil ? 400 : 340
                ZStack(alignment: .topLeading) {
                    // On paper the shade is laid twice: once is too light to set the page back.
                    ForEach(0..<(colorScheme == .dark ? 1 : 2), id: \.self) { _ in
                        TourShade(hole: hole, header: page).fill(Palette.shadow, style: FillStyle(eoFill: true))
                    }
                    // Clicks on the shade go nowhere; the openings let them through.
                    Color.clear.contentShape(TourShade(hole: hole, header: page), eoFill: true).onTapGesture {}
                        .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: TourShade.radius, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .opacity(found == nil ? 0 : 1)
                        .allowsHitTesting(false)
                    TourCard(index: index)
                        .frame(width: width)
                        .background(GeometryReader { Color.clear.preference(key: CardHeight.self, value: $0.size.height) })
                        .offset(place(card: CGSize(width: width, height: cardHeight), centred: stop.target == nil, in: proxy.size))
                }
                .onPreferenceChange(CardHeight.self) { cardHeight = $0 }
                .onChange(of: Reached(index: index, rect: found), initial: true) { _, reached in TourLayer.reached[reached.index] = reached.rect }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: Motion.slow), value: index)
            .transition(.opacity)
        }
    }

    /// In the bottom right corner, over what matters least on any page and in the same place at
    /// every stop; in the middle when the stop points at nothing in the window.
    private func place(card: CGSize, centred: Bool, in size: CGSize) -> CGSize {
        let margin = Space.xl
        if centred { return CGSize(width: (size.width - card.width) / 2, height: max(margin, (size.height - card.height) / 2)) }
        return CGSize(width: size.width - card.width - margin, height: max(margin, size.height - card.height - margin))
    }
}

private struct CardHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The whole window with two rounded openings, one for the sidebar item and one for the page's
/// header. They move from stop to stop.
struct TourShade: Shape {
    static let radius = Radius.md + 4
    var hole: CGRect
    var header: CGRect
    var animatableData: AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData> {
        get { AnimatablePair(hole.animatableData, header.animatableData) }
        set { hole.animatableData = newValue.first; header.animatableData = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for opening in [hole, header] where opening.width > 0 && opening.height > 0 {
            let radius = min(Self.radius, opening.height / 2)
            path.addRoundedRect(in: opening, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

/// What a stop says, and the way on.
private struct TourCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let index: Int
    var body: some View {
        let count = model.tourStops.count, last = index == count - 1
        let words = text
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center) {
                Rubric(text: t("\(index + 1) of \(count)", "\(index + 1) di \(count)"))
                Spacer()
                IconButton(symbol: "xmark", label: t("End the tour", "Chiudi il tour")) { model.endTour() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.vertical, -Space.md).padding(.trailing, -Space.sm)
            }
            Text(words.title).font(Typeface.display(TypeSize.title3, .medium)).foregroundStyle(Palette.textPrimary).accessibilityAddTraits(.isHeader)
            Text(words.body).font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.ui))
                .fixedSize(horizontal: false, vertical: true)
            if model.tourStops[index].target == nil { MenuBarSketch(compact: true).padding(.top, Space.xs) }
            HStack(spacing: Space.sm) {
                if index > 0 {
                    Button(t("Back", "Indietro")) { model.moveTour(to: index - 1) }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                }
                Spacer()
                Button(last ? t("Close the tour", "Chiudi il tour") : t("Next", "Avanti")) { model.moveTour(to: index + 1) }
                    .buttonStyle(VerbButtonStyle(kind: .primary, compact: true)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, Space.xs)
            // The arrow keys move through the stops too.
            .background {
                Button("") { model.moveTour(to: index + 1) }.keyboardShortcut(.rightArrow, modifiers: []).opacity(0).accessibilityHidden(true)
                Button("") { if index > 0 { model.moveTour(to: index - 1) } }.keyboardShortcut(.leftArrow, modifiers: []).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(Space.lg)
        .background {
            // The shadow belongs to the sheet alone, not to every word on it.
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Palette.surfaceRaised).shadow(color: Palette.shadow, radius: 24, y: 10)
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.borderSubtle))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Tour", "Tour"))
        // VoiceOver reads each stop as it comes.
        .onChange(of: index, initial: true) { _, _ in AccessibilityNotification.Announcement(words.title + ". " + words.body).post() }
    }

    private var text: (title: String, body: String) {
        let keys = model.settings.keyOptions
        let dictate = model.dictationKeys(t)
        switch model.tourStops[index].target {
        case .page(.home):
            return (t("Home", "Home"), t("Your latest dictation leads the page, with your speed and the days you dictate. Dictate starts a hands-free dictation from here.",
                                         "L’ultima dettatura apre la pagina, con la tua velocità e i giorni in cui detti. Detta avvia da qui una dettatura a mani libere."))
        case .page(.history):
            return (t("History", "Cronologia"), t("Every dictation, kept on this Mac for as long as you choose, and its recording for up to 14 days. Copy it, listen to it, retry one that failed, or drop in an audio file to have it written down.",
                                                  "Ogni dettatura, conservata su questo Mac per il tempo che scegli, e la sua registrazione fino a 14 giorni. Copiala, riascoltala, riprova quelle non riuscite, o trascina qui un file audio per trascriverlo."))
        case .page(.notes):
            let notepad = keys.notepad.map { t.inlineKeys($0.label) }
            return (t("Notes", "Note"), (notepad.map { t("\($0) opens the notepad over any app, and you dictate into it as into any field. ", "\($0) apre il blocco note sopra qualsiasi app, e ci detti come in ogni campo. ") } ?? "")
                    + t("Record a meeting writes down both sides of a call, then the notes. Everything is kept as Markdown files.", "Registra una riunione trascrive entrambe le parti di una chiamata, poi le note. Tutto resta in file Markdown."))
        case .words:
            let first = model.library.transforms.first?.keys.map { t.inlineKeys($0.label) }
            return (t("Dictionary, snippets, transforms", "Dizionario, frasi pronte, trasformazioni"),
                    t("The Dictionary spells names and terms your way, and offers the words you retype after a dictation. Snippets turn a short phrase into a whole text. Transforms rewrite the text you select with a prompt of yours",
                      "Il Dizionario scrive nomi e termini a modo tuo, e ti propone le parole che riscrivi dopo una dettatura. Le frasi pronte trasformano una frase breve in un testo intero. Le trasformazioni riscrivono con un tuo prompt il testo selezionato")
                    + (first.map { t(": press \($0) in any app.", ": premi \($0) in qualsiasi app.") } ?? "."))
        case .page(.models):
            return (t("Models", "Modelli"), t("Where your words are recognized and tidied up: on this Mac, as they are by default, or with a server or a subscription you already have, such as Claude or Codex.",
                                              "Dove le tue parole vengono riconosciute e messe in bella: su questo Mac, come per impostazione predefinita, oppure con un server o un abbonamento che hai già, come Claude o Codex."))
        case .page(.settings):
            return (t("Settings", "Impostazioni"), t("Your keys, the overlay’s style, “Hey \(model.settings.voiceOptions.spokenName)”, a writing style for each app and how long history is kept.",
                                                     "I tuoi tasti, lo stile della capsula, “Ehi \(model.settings.voiceOptions.spokenName)”, uno stile di scrittura per ogni app e per quanto tempo resta la cronologia."))
        case .footer:
            return (t("Always in view", "Sempre sott’occhio"), t("Here you see whether anything leaves this Mac and which keys dictate. The last row chooses the appearance: automatic, light or dark.",
                                                                 "Qui vedi se qualcosa esce da questo Mac e con quali tasti detti. L’ultima riga sceglie l’aspetto: automatico, chiaro o scuro."))
        case .page(.dictionary), .page(.snippets), .page(.transforms), .header:
            return ("", "")
        case nil:
            return (t("In the menu bar", "Nella barra dei menu"), t("Close the window with ⌘W and Verb stays up here, ready for \(dictate). Its menu starts a dictation, opens the notepad, records a meeting and switches the writing model.",
                                                                    "Chiudi la finestra con ⌘W e Verb resta qui, pronto per \(dictate). Il suo menu avvia una dettatura, apre il blocco note, registra una riunione e cambia il modello di scrittura."))
        }
    }
}
