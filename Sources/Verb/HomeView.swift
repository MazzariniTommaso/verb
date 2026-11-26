import SwiftUI
import VerbCore

/// Home leads with the words. The last dictation is the page's headline, set on the paper in
/// New York; everything else (the date, the instruction, the totals) steps back around it.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.pageLayout) private var layout
    @State private var detail: DictationRecord?
    var body: some View {
        // In a large window the cards go two by two, in a wider column, rather than leave the room empty.
        PageScroll(cap: layout.size == .extraLarge ? Sizing.gridExtraLarge : layout.sideBySide ? Sizing.gridLarge : Sizing.contentMax) {
            header
            if needsSetup { FirstSteps() }
            // Your words first; the numbers after them.
            if model.latestText.isEmpty { FirstPage() } else { LatestWords() }
            let typing = model.settings.coachingState.typingSpeed ?? DictationStats.typingWordsPerMinute
            let stats = model.stats.dictations > 0 ? StatsCard(stats: model.stats, typing: typing) : nil
            let week = model.stats.dictations > 0 ? WeekCard(recap: model.stats.recap(typing: typing)) : nil
            let before = earlier.isEmpty ? nil : Earlier(records: earlier) { detail = $0 }
            let activity = model.stats.dictations > 0 ? ActivityCard(stats: model.stats) : nil
            if layout.sideBySide {
                pair(stats, week).environment(\.cardsMatchHeight, true)
                pair(before, activity)
            } else {
                stats; week; before; activity
            }
        }
        .sheet(item: $detail) { HistoryDetail(record: $0).environmentObject(model).environment(\.lang, t).environment(\.locale, t.locale) }
    }

    /// Two sections side by side, equally wide; one alone takes the row.
    @ViewBuilder private func pair<A: View, B: View>(_ first: A?, _ second: B?) -> some View {
        if let first, let second {
            HStack(alignment: .top, spacing: layout.gutter) {
                first.frame(maxWidth: .infinity, alignment: .topLeading)
                second.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if let first { first } else if let second { second }
    }

    /// A greeting for the time of day.
    static func greeting(_ t: Lang, at date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return t("Good morning", "Buongiorno")
        case 12..<18: return t("Good afternoon", "Buon pomeriggio")
        case 18..<23: return t("Good evening", "Buonasera")
        default: return t("Working late", "Si lavora tardi")
        }
    }
    /// The writing model is optional: dictation works without it, so it never keeps this up alone.
    private var needsSetup: Bool { !model.microphoneGranted || !model.accessibilityGranted || !model.speechReady }
    /// The dictations before the latest one, at most three, skipping entries with no text.
    private var earlier: [DictationRecord] {
        let rest = model.history.filter { !$0.text.isEmpty && $0.text != model.latestText }
        return Array(rest.prefix(3))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Rubric(text: Self.greeting(t) + " · " + Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(t.locale)))
                // While Verb listens or works, the live line takes the instruction's place, so nothing below moves.
                Group {
                    if model.busy { LiveLine(meter: model.meter) }
                    else {
                        Text(model.startHint(t) + ". " + t("Verb writes wherever your cursor is.", "Verb scrive dove si trova il cursore."))
                            .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(minHeight: 26, alignment: .leading)
            }
            Spacer(minLength: 0)
            controls
        }
        .tourAnchor(.header)
    }

    @ViewBuilder private var controls: some View {
        if model.phase == .recording {
            HStack(spacing: Space.sm) {
                Button(t("Cancel", "Annulla")) { model.cancel() }.buttonStyle(VerbButtonStyle(kind: .quiet))
                Button { model.finish() } label: { Label(t("Finish", "Termina"), systemImage: "stop.fill") }.buttonStyle(VerbButtonStyle(kind: .primary))
            }
        } else if model.busy {
            Button(t("Cancel", "Annulla")) { model.cancel() }.buttonStyle(VerbButtonStyle(kind: .secondary))
        } else {
            // While setup is unfinished the next step is the primary action, not dictation.
            Button { model.handsFree = true; model.begin() } label: { Label(t("Dictate", "Detta"), systemImage: "mic") }
                .buttonStyle(VerbButtonStyle(kind: needsSetup ? .secondary : .primary))
                .help(model.keysCantFinish ? t("Starts hands-free dictation. Finish it from the overlay or the menu.", "Avvia la dettatura a mani libere. Terminala dalla capsula o dal menu.")
                                           : t("Starts hands-free dictation. Press Space to finish.", "Avvia la dettatura a mani libere. Premi Spazio per finire."))
        }
    }

}

/// How fast you write by voice, and how much. Words per minute lead, set against the usual
/// speed of typing; the totals follow. They count every dictation, also those History no
/// longer keeps.
struct StatsCard: View {
    @Environment(\.lang) private var t
    @Environment(\.pageLayout) private var layout
    let stats: DictationStats
    /// Your typing speed when the welcome measured it; otherwise the usual average.
    var typing = DictationStats.typingWordsPerMinute
    var body: some View {
        Card {
            if layout.size == .small {
                // In a small window the speed stands over its bars, and the totals keep their thirds.
                VStack(alignment: .leading, spacing: Space.lg) {
                    speed
                    bars
                    Hairline()
                    HStack(alignment: .top, spacing: Space.xl) { totals }
                }
            } else {
                // One grid for both rows, in thirds, so the speed, the bars and the totals line up in either language.
                Grid(alignment: .topLeading, horizontalSpacing: Space.xl, verticalSpacing: 0) {
                    GridRow {
                        speed.frame(maxWidth: .infinity, alignment: .leading)
                        bars.frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.lg).gridCellColumns(2)
                    }
                    GridRow { Hairline().padding(.vertical, Space.lg).gridCellColumns(3) }
                    GridRow { totals }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var speed: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Overline(text: t("Words per minute", "Parole al minuto"))
            Text(stats.wordsPerMinute.map { Int($0.rounded()).formatted(.number.locale(t.locale)) } ?? "–")
                .accessibilityLabel(stats.wordsPerMinute.map { Int($0.rounded()).formatted(.number.locale(t.locale)) } ?? t("Not measured yet", "Non ancora misurato"))
                .font(Typeface.display(TypeSize.hero, .medium)).tracking(Tracking.display).monospacedDigit().foregroundStyle(Palette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let wpm = stats.wordsPerMinute {
                Text(t("\((wpm / typing).formatted(.number.precision(.fractionLength(1)).locale(t.locale)))× the speed of typing", "\((wpm / typing).formatted(.number.precision(.fractionLength(1)).locale(t.locale)))× la velocità della tastiera"))
                    .font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text(stats.leavesOutPauses ? t("Counting only the time you speak, pauses left out.", "Conta solo il tempo in cui parli, senza le pause.") : t("Pauses included, until Verb has measured enough of your voice.", "Pause comprese, finché Verb non ha misurato abbastanza la tua voce."))
                    .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("Dictate a little more to see your speed.", "Detta ancora un po’ per vedere la tua velocità.")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            let voice = stats.wordsPerMinute ?? 0, longest = max(voice, typing)
            bar(t("You, by voice", "Tu, a voce"), value: voice, of: longest, color: Palette.textPrimary)
            bar(measured ? t("You, typing", "Tu, alla tastiera") : t("Typing, on average", "Tastiera, in media"), value: typing, of: longest, color: Palette.textTertiary)
            Text(saved).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                .help(measured ? t("Your typing speed, as the welcome measured it.", "La tua velocità alla tastiera, misurata nell’introduzione.") : t("The typing average is about 40 words a minute, the figure most often quoted for computer keyboards.", "La media alla tastiera è di circa 40 parole al minuto, la cifra più citata per chi scrive al computer."))
        }
    }

    @ViewBuilder private var totals: some View {
        total(stats.words.formatted(.number.locale(t.locale)), stats.words == 1 ? t("word dictated", "parola dettata") : t("words dictated", "parole dettate"))
        total(minutes, stats.seconds >= 60 && stats.seconds < 120 ? t("minute of speech", "minuto di voce") : t("minutes of speech", "minuti di voce"))
        total(stats.dictations.formatted(.number.locale(t.locale)), stats.dictations == 1 ? t("dictation", "dettatura") : t("dictations", "dettature"))
    }

    private var minutes: String {
        let value = stats.seconds / 60
        return value < 10 ? value.formatted(.number.precision(.fractionLength(1)).locale(t.locale)) : Int(value.rounded()).formatted(.number.locale(t.locale))
    }
    private var measured: Bool { typing != DictationStats.typingWordsPerMinute }
    /// The time the same words would have taken at the keyboard, less the time spent saying them.
    private var saved: String {
        let minutes = Double(stats.words) / typing - stats.seconds / 60
        guard minutes >= 1 else { return measured ? t("You type about \(Int(typing.rounded())) words a minute.", "Scrivi circa \(Int(typing.rounded())) parole al minuto alla tastiera.") : t("Typing averages about 40 words a minute.", "Alla tastiera la media è di circa 40 parole al minuto.") }
        let time = minutes >= 90 ? t.count(Int((minutes / 60).rounded()), "hour", "hours", "ora", "ore") : t.count(Int(minutes.rounded()), "minute", "minutes", "minuto", "minuti")
        return t("About \(time) saved compared with typing.", "Hai risparmiato circa \(time) rispetto alla tastiera.")
    }
    private func bar(_ label: String, value: Double, of longest: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(Int(value.rounded()).formatted(.number.locale(t.locale))).font(Typeface.text(TypeSize.footnote, .semibold)).monospacedDigit().foregroundStyle(Palette.textPrimary)
            }
            GeometryReader { proxy in
                Capsule().fill(Palette.fillPressed)
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: longest > 0 ? max(6, proxy.size.width * value / longest) : 0) }
            }
            .frame(height: 10)
        }
    }
    private func total(_ number: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number).font(Typeface.display(TypeSize.title1, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// While Verb listens or works, one line under the heading says so. The overlay says the same over other apps.
private struct LiveLine: View {
    @EnvironmentObject var model: AppModel
    let meter: LevelMeter
    @Environment(\.lang) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: Space.md) {
            if model.phase == .recording { LiveDot(meter: meter) } else { InkSpinner(size: 16) }
            Text(model.phaseTitle(t)).font(Typeface.display(TypeSize.callout).italic()).foregroundStyle(Palette.textPrimary)
            Text(model.phase == .recording ? durationLabel(model.elapsed) : model.location(t)).font(Typeface.text(TypeSize.footnote)).monospacedDigit().foregroundStyle(Palette.textSecondary)
            if model.phase == .recording { VoiceDotsView(meter: meter, color: Palette.textPrimary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown until the three things dictation needs are in place, with the optional writing model
/// after them. It is the lifted card while it is here, and the next unfinished step carries the
/// page's one primary button.
private struct FirstSteps: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        let done = [model.microphoneGranted, model.accessibilityGranted, model.speechReady, model.writerReady]
        let next = done.prefix(3).firstIndex(of: false)
        Card(lifted: true) {
            SectionHeading(title: t("First steps", "Primi passi"), detail: t("Three things, once, and a fourth if you like. Then Verb stays out of your way.", "Tre cose, una volta sola, e una quarta se vuoi. Poi Verb non ti disturba più."))
            VStack(spacing: 0) {
                step(0, next, t("Microphone", "Microfono"), t("Verb listens while you dictate or record a meeting, and for “Hey \(model.settings.voiceOptions.spokenName)” if you turn it on.", "Verb ascolta mentre detti o registri una riunione e, se lo attivi, per sentire “Ehi \(model.settings.voiceOptions.spokenName)”.")
                     + (model.settings.duckAudio ? t(" Music and videos go quieter while you speak.", " Mentre parli, musica e video si abbassano.") : ""), done: done[0], action: t("Allow the microphone", "Consenti il microfono")) { model.requestMicrophone() }
                Hairline()
                step(1, next, t("Accessibility", "Accessibilità"), model.settings.keyOptions.dictation == nil ? t("Lets Verb type into other apps.", "Permette a Verb di scrivere nelle altre app.")
                     : t("Lets \(t.keys(model.settings.keyOptions.dictation)) start dictation and Verb type into other apps.", "Permette a \(t.keys(model.settings.keyOptions.dictation)) di avviare la dettatura e a Verb di scrivere nelle altre app."), done: done[1], action: t("Allow Accessibility", "Consenti l’Accessibilità")) { model.requestAccessibility() }
                Hairline()
                step(2, next, t("Speech model", "Modello vocale"), t("Recognition in Italian, English and many other languages, on this Mac.", "Riconoscimento in italiano, inglese e molte altre lingue, su questo Mac."), done: done[2], action: t("Open Models", "Apri Modelli")) { model.page = .models }
                Hairline()
                step(3, next, t("Writing model · optional", "Modello di scrittura · facoltativo"), t("Removes fillers and resolves spoken corrections. Without it, Verb’s own rules tidy each dictation.", "Toglie gli intercalari e risolve le correzioni dette a voce. Senza, ci pensano le regole di Verb."), done: done[3], action: t("Open Models", "Apri Modelli")) { model.page = .models }
            }
            .padding(.top, Space.md)
        }
    }
    private func step(_ index: Int, _ next: Int?, _ title: String, _ detail: String, done: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Space.base) {
            Text("\(index + 1)").font(Typeface.display(TypeSize.title3).italic()).foregroundStyle(done ? Palette.textTertiary : Palette.accent).frame(width: 18)
            RowLabel(title: title, detail: detail)
            if done { StatusLabel(text: t("Done", "Fatto"), symbol: "checkmark", tone: .success) }
            else { Button(action, action: perform).buttonStyle(VerbButtonStyle(kind: index == next ? .primary : .secondary, compact: true)) }
        }
        .padding(.vertical, Space.sm)
        .frame(minHeight: Sizing.controlMin + Space.sm)
        .accessibilityElement(children: .contain)
    }
}

/// The last dictation as the page's headline. Short sentences are set at title size, long ones a
/// step smaller; the opening quote hangs in the margin so the words align with everything else.
private struct LatestWords: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    @Environment(\.pageLayout) private var layout
    var body: some View {
        let record = model.history.first { $0.text == model.latestText }
        // A step smaller in a small window, where the headline would otherwise fill it.
        let size = model.latestText.count <= 140 && layout.size != .small ? TypeSize.title1 : TypeSize.title2
        return VStack(alignment: .leading, spacing: Space.base) {
            HStack(spacing: Space.sm) {
                Overline(text: t("Latest", "Ultima"))
                if let record {
                    Text(t.message(record.appName) + " · " + t.relativeTime(record.createdAt)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                }
            }
            // The quote hangs only where the margin has room for it; a narrow one keeps the words alone.
            let hangs = layout.margin >= Space.xxxl
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if hangs { Text("“").font(Typeface.display(size * 1.25)).foregroundStyle(Palette.accent).frame(width: 24, alignment: .trailing).accessibilityHidden(true) }
                Text(model.latestText).font(Typeface.display(size)).tracking(size > TypeSize.title2 ? Tracking.display : 0).foregroundStyle(Palette.textPrimary)
                    .lineSpacing(leading(size, 1.3)).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, hangs ? -30 : 0)
            HStack(spacing: Space.sm) {
                // What happened to this dictation, not whatever the app did last.
                Text(([t.count(model.latestText.split(whereSeparator: \.isWhitespace).count, "word", "words", "parola", "parole")] + (record.map { [t.outcome($0.delivery)] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Spacer(minLength: Space.base)
                Button(t("Open in History", "Apri nella Cronologia")) { model.historyFocus = record?.id; model.page = .history }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                Button { model.copy(model.latestText) } label: { Label(t("Copy", "Copia"), systemImage: "doc.on.doc") }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(.vertical, Space.sm)
    }
}

/// Before the first dictation, the motto takes the headline's place.
private struct FirstPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        let keys = t.keys(model.settings.keyOptions.dictation)
        VStack(alignment: .leading, spacing: Space.md) {
            Rubric(text: t("Your first page", "La tua prima pagina"))
            Text("Verba volant, scripta manent.").font(Typeface.display(TypeSize.title1).italic()).tracking(Tracking.display).foregroundStyle(Palette.textPrimary)
            Text(model.settings.keyOptions.dictation == nil
                 ? t("Spoken words fly away; written ones stay. To try it, choose dictation keys in Settings → Keyboard, or press Dictate and say: “Let’s meet on Tuesday, actually Wednesday, at three.”",
                     "Le parole dette volano, quelle scritte restano. Per provare, scegli i tasti della dettatura in Impostazioni → Tastiera, oppure premi Detta e di’: “Ci vediamo martedì, anzi mercoledì, alle tre.”")
                 : t("Spoken words fly away; written ones stay. To try it, hold \(keys) and say: “Let’s meet on Tuesday, actually Wednesday, at three.”",
                     "Le parole dette volano, quelle scritte restano. Per provare, tieni premuto \(keys) e di’: “Ci vediamo martedì, anzi mercoledì, alle tre.”"))
                .font(Typeface.text(TypeSize.body)).foregroundStyle(Palette.textSecondary).lineSpacing(leading(TypeSize.body, Leading.reading))
                .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.sm)
    }
}

/// The few dictations before the latest, so Home is a page of writing rather than a single line.
private struct Earlier: View {
    let records: [DictationRecord]
    let open: (DictationRecord) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Overline(text: t("Earlier", "Precedenti"))
                Spacer()
                Button(t("See all dictations", "Vedi tutte le dettature")) { model.page = .history }.buttonStyle(VerbButtonStyle(kind: .link, compact: true))
            }
            RowList {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Hairline().padding(.horizontal, Space.lg) }
                    EarlierRow(record: record) { open(record) }
                }
            }
        }
    }
}

private struct EarlierRow: View {
    let record: DictationRecord
    let action: () -> Void
    @Environment(\.lang) private var t
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                Text(record.text).font(Typeface.display(TypeSize.callout)).foregroundStyle(Palette.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(t.message(record.appName) + " · " + t.relativeTime(record.createdAt)).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(hovering ? Palette.fillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onPointerOver { hovering = $0 }
        .accessibilityHint(t("Opens the entry", "Apre la voce"))
    }
}

/// The recording dot: its halo swells with your voice.
struct LiveDot: View {
    let meter: LevelMeter
    var size: CGFloat = 20
    var color: Color = Palette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let level = CGFloat(meter.level(at: meter.now(timeline.date)))
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: size, height: size).scaleEffect(reduceMotion ? 1 : 0.8 + level * 0.6)
                Circle().fill(color).frame(width: size * 0.45, height: size * 0.45)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The days you dictate, month by month, what Verb put right and where you use it.
struct ActivityCard: View {
    @Environment(\.lang) private var t
    let stats: DictationStats
    /// How many weeks the map shows.
    static let weeks = 15
    var body: some View {
        let streak = stats.streak()
        let now = Date(), lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        let month = stats.words(inMonthOf: now), previous = stats.words(inMonthOf: lastMonth)
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                Overline(text: t("Your activity", "La tua attività"))
                HStack(alignment: .top, spacing: Space.xl) {
                    figure(t.count(streak.current, "day", "days", "giorno", "giorni"),
                           streak.longest > streak.current ? t("in a row · best \(streak.longest)", "di fila · record \(streak.longest)") : t("in a row, your best", "di fila, il tuo record"))
                    figure(month.formatted(.number.locale(t.locale)), change(month, previous))
                    figure(stats.fixes.formatted(.number.locale(t.locale)), stats.fixes == 1 ? t("automatic correction", "correzione automatica") : t("automatic corrections", "correzioni automatiche"))
                        .help(t("Hesitations and repeats taken out, dictionary corrections and snippets.", "Esitazioni e ripetizioni tolte, correzioni del dizionario e frasi pronte."))
                }
                Hairline()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.xxl) { heatmap; apps.frame(maxWidth: .infinity, alignment: .leading) }
                    VStack(alignment: .leading, spacing: Space.xl) { heatmap; apps }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func change(_ month: Int, _ previous: Int) -> String {
        let label = t("words this month", "parole questo mese")
        guard previous > 0 else { return label }
        let percent = Int((Double(month - previous) / Double(previous) * 100).rounded())
        // A true minus sign, not a hyphen.
        return label + " · " + (percent >= 0 ? "+" : "−") + "\(abs(percent))% " + t("on last month", "sul mese scorso")
    }
    private func figure(_ number: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number).font(Typeface.display(TypeSize.title2, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One square a day, weeks from left to right, Monday at the top; darker for more words, in
    /// four clear steps. A day without words is only outlined, so the map reads without colour.
    private var heatmap: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7 // Monday 0 … Sunday 6
        let start = calendar.date(byAdding: .day, value: -(Self.weeks - 1) * 7 - weekday, to: today) ?? today
        let values = stats.days.values.filter { $0 > 0 }.sorted()
        func level(_ words: Int) -> Double {
            guard words > 0, !values.isEmpty else { return 0 }
            let rank = Double(values.firstIndex { $0 >= words } ?? values.count - 1) / Double(max(values.count - 1, 1))
            return [0.45, 0.65, 0.82, 1.0][min(3, Int(rank * 4))]
        }
        // What the map shows, in words, for VoiceOver.
        let shown = (0..<(Self.weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.filter { $0 <= today }
        let counts = shown.map { (day: $0, words: stats.days[DictationStats.day($0)] ?? 0) }
        let best = counts.max { $0.words < $1.words }
        let summary = t("Dictated on \(t.count(counts.filter { $0.words > 0 }.count, "day", "days", "giorno", "giorni")) of the last \(Self.weeks) weeks", "Hai dettato in \(t.count(counts.filter { $0.words > 0 }.count, "giorno", "giorni", "giorno", "giorni")) delle ultime \(Self.weeks) settimane")
            + (best.map { $0.words > 0 ? t(". Most on \($0.day.formatted(.dateTime.day().month(.wide).locale(t.locale))): \(t.count($0.words, "word", "words", "parola", "parole"))", ". Di più il \($0.day.formatted(.dateTime.day().month(.wide).locale(t.locale))): \(t.count($0.words, "word", "words", "parola", "parole"))") : "" } ?? "")
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row % 2 == 0 ? weekdayInitial(row) : "").font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).frame(width: 12, height: 12, alignment: .trailing)
                    }
                }
                ForEach(0..<Self.weeks, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = calendar.date(byAdding: .day, value: week * 7 + row, to: start) ?? start
                            let words = stats.days[DictationStats.day(day)] ?? 0
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day > today || words == 0 ? Color.clear : Palette.textPrimary.opacity(level(words)))
                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(day <= today && words == 0 ? Palette.borderStrong.opacity(0.6) : .clear))
                                .frame(width: 12, height: 12)
                                .help(day > today ? "" : day.formatted(.dateTime.day().month(.abbreviated).locale(t.locale)) + ": " + t.count(words, "word", "words", "parola", "parole"))
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text(t("Less", "Meno")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
                RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.borderStrong.opacity(0.6)).frame(width: 10, height: 10)
                ForEach([0.45, 0.65, 0.82, 1.0], id: \.self) { RoundedRectangle(cornerRadius: 3).fill(Palette.textPrimary.opacity($0)).frame(width: 10, height: 10) }
                Text(t("More", "Di più")).font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textTertiary)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("Activity", "Attività"))
        .accessibilityValue(summary)
    }
    private func weekdayInitial(_ row: Int) -> String {
        let symbols = t.locale.identifier.hasPrefix("it") ? ["L", "M", "M", "G", "V", "S", "D"] : ["M", "T", "W", "T", "F", "S", "S"]
        return symbols[row]
    }

    /// Where the words go: the apps with the most.
    private var apps: some View {
        let top = stats.topApps(4), most = Double(top.first?.words ?? 1)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(t("Where you dictate", "Dove detti")).font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textPrimary)
            ForEach(top, id: \.name) { app in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.message(app.name)).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        Spacer()
                        Text(app.words.formatted(.number.locale(t.locale))).font(Typeface.text(TypeSize.footnote, .semibold)).monospacedDigit().foregroundStyle(Palette.textPrimary)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Palette.fillPressed)
                            .overlay(alignment: .leading) { Capsule().fill(Palette.textTertiary).frame(width: max(4, proxy.size.width * Double(app.words) / most)) }
                    }
                    .frame(height: 6)
                }
            }
        }
        .frame(minWidth: 200)
    }
}

/// The last seven days against the seven before: words, days, time saved and where.
struct WeekCard: View {
    @Environment(\.lang) private var t
    let recap: WeekRecap
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                Overline(text: t("Your week", "La tua settimana"))
                HStack(alignment: .top, spacing: Space.xl) {
                    figure(recap.words.formatted(.number.locale(t.locale)), change)
                    figure(t.count(recap.activeDays, "day", "days", "giorno", "giorni"), t("with a dictation, of seven", "con una dettatura, su sette"))
                    figure(recap.minutesSaved >= 90 ? t.count(Int((Double(recap.minutesSaved) / 60).rounded()), "hour", "hours", "ora", "ore") : t.count(recap.minutesSaved, "minute", "minutes", "minuto", "minuti"),
                           t("saved against typing", "risparmiati sulla tastiera"))
                }
                if let app = recap.topApp {
                    Text(t("You dictate most in \(app).", "Detti soprattutto in \(app).")).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var change: String {
        guard let change = recap.change else { return recap.words == 1 ? t("word this week", "parola questa settimana") : t("words this week", "parole questa settimana") }
        let percent = abs(change).formatted(.percent.precision(.fractionLength(0)).locale(t.locale))
        return change >= 0 ? t("words, \(percent) more than last week", "parole, \(percent) in più della scorsa") : t("words, \(percent) fewer than last week", "parole, \(percent) in meno della scorsa")
    }
    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(value).font(Typeface.display(TypeSize.title2, .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
