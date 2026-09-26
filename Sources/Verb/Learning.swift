import AppKit
import SwiftUI
import VerbCore

// The dictionary that learns from your corrections. For about 45 seconds after a paste, Verb
// rereads the words it wrote in that field; a word you retype there ("Tomaso" into "Tommaso")
// is offered to the dictionary in the overlay, and waits on the Dictionary page if you let the
// moment pass. Nothing is added without your yes, and a word you turn down isn't offered again.
// Like everything read from other apps, the words waiting for an answer stay in memory; a word
// turned down is remembered only as a digest.

extension AppModel {
    func watchCorrections(pasted text: String, target: TextTarget, location: Int) {
        learner?.cancel()
        guard let element = target.element, !target.secure, !text.isEmpty else { return }
        let length = (text as NSString).length
        // Letters and digits only: an app may turn quotes curly or drop a space as it pastes.
        func gist(_ value: String) -> String { String(value.filter { $0.isLetter || $0.isNumber }.prefix(16)) }
        learner = Task { [weak self] in
            // What Verb wrote must be there, or this is not the field it wrote into. A busy app may take a moment to show it.
            var found = false
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                if let first = FieldContext.text(element, CFRange(location: location, length: length + 2)), gist(first) == gist(text) { found = true; break }
            }
            guard found else { return }
            var offered = Set<String>(), seen: [String: Int] = [:]
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let current = FieldContext.text(element, CFRange(location: location, length: length + 40)) else { return }
                for change in CorrectionLearner.changes(inserted: text, current: current) {
                    let key = change.heard + "→" + change.written
                    // A word counts once it has stayed the same for a moment: it is finished.
                    seen[key, default: 0] += 1
                    let names = AppModel.properNames(in: current)
                    guard seen[key, default: 0] >= 2, !offered.contains(key),
                          let suggestion = CorrectionLearner.suggestion(for: change, isOrdinary: AppModel.isOrdinary, isName: { names.contains($0) || ($0.first?.isUppercase == true && !AppModel.isOrdinary($0.lowercased())) }) else { continue }
                    offered.insert(key)
                    self.offer(suggestion)
                }
            }
        }
    }

    /// Keeps the suggestion for the Dictionary page and, when nothing else is happening, asks in the overlay.
    func offer(_ suggestion: CorrectionLearner.Suggestion) {
        let entry: VocabularySuggestion
        switch suggestion {
        case .replace(let heard, let word): entry = VocabularySuggestion(word: word, heardAs: heard)
        case .spelling(let word): entry = VocabularySuggestion(word: word, heardAs: "")
        }
        guard !(library.ignored ?? []).contains(Library.ignoreKey(heard: entry.heardAs, word: entry.word)) else { return }
        let known = library.vocabulary.contains { $0.word == entry.word && (entry.heardAs.isEmpty || TextRules.canonical($0.heardAs) == TextRules.canonical(entry.heardAs)) }
        guard !known else { return }
        suggestions = Array((suggestions.filter { !($0.word == entry.word && $0.heardAs == entry.heardAs) } + [entry]).suffix(30))
        guard !busy else { return }
        pendingSuggestion = entry
        flashOutcome?()
    }

    func acceptSuggestion(_ entry: VocabularySuggestion) {
        suggestions.removeAll { $0.id == entry.id }
        var updated = library
        let result = LibraryTransfer.merge([VocabularyEntry(word: entry.word, heardAs: entry.heardAs)], into: &updated.vocabulary, snippets: updated.snippets)
        library = updated
        guard pendingSuggestion?.id == entry.id else { return }
        pendingSuggestion = nil
        guard !busy else { return }
        status = result.added > 0 ? "“\(entry.word)” is in the dictionary." : "“\(entry.word)” was already in the dictionary."
        outcome = .learned
        flashOutcome?()
    }

    func dismissSuggestion(_ entry: VocabularySuggestion) {
        suggestions.removeAll { $0.id == entry.id }
        var updated = library
        updated.ignored = Array(((updated.ignored ?? []) + [Library.ignoreKey(heard: entry.heardAs, word: entry.word)]).suffix(200))
        library = updated
        if pendingSuggestion?.id == entry.id { pendingSuggestion = nil; flashOutcome?() }
    }
}

/// In the overlay: "Add “Tommaso” to the dictionary?", with Add and a small cross.
struct SuggestionPrompt: View {
    @EnvironmentObject var model: AppModel
    let entry: VocabularySuggestion
    var body: some View {
        let t = model.lang
        HStack(spacing: Space.sm) {
            Image(systemName: "character.book.closed").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(t("Add “\(entry.word)” to the dictionary?", "Aggiungere “\(entry.word)” al dizionario?"))
                    .font(Typeface.text(TypeSize.footnote, .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(entry.heardAs.isEmpty ? t("You corrected it after the dictation", "L’hai corretta dopo la dettatura") : t("Verb wrote “\(entry.heardAs)”", "Verb aveva scritto “\(entry.heardAs)”"))
                    .font(Typeface.text(TypeSize.caption)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            // Small to look at, the full height of the capsule to hit.
            Button { model.acceptSuggestion(entry) } label: {
                Text(t("Add", "Aggiungi")).font(Typeface.text(TypeSize.footnote, .semibold)).foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10).frame(height: 26).background(Palette.fillHover, in: Capsule())
                    .frame(minHeight: Sizing.controlMin).contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            MiniButton(kind: .cancel, size: 20) { model.dismissSuggestion(entry) }
                .help(t("Don’t add it, and don’t ask again", "Non aggiungerla e non chiedere più"))
                .accessibilityLabel(t("Don’t add it", "Non aggiungerla"))
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(height: 44)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.borderSubtle))
        .accessibilityElement(children: .contain)
    }
}

/// On the Dictionary page: the words noticed in your corrections, to add or turn down.
struct SuggestionList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.lang) private var t
    let suggestions: [VocabularySuggestion]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Rubric(text: t("Noticed in your corrections", "Notate nelle tue correzioni"))
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Hairline() }
                    HStack(spacing: Space.md) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.word).font(Typeface.display(TypeSize.reading)).foregroundStyle(Palette.textPrimary)
                            Text(entry.heardAs.isEmpty ? t("A spelling to prefer", "Una grafia da preferire") : t("Replaces “\(entry.heardAs)”", "Sostituisce “\(entry.heardAs)”"))
                                .font(Typeface.text(TypeSize.footnote)).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Button(t("Don’t add", "Non aggiungere")) { model.dismissSuggestion(entry) }.buttonStyle(VerbButtonStyle(kind: .quiet, compact: true))
                        Button(t("Add", "Aggiungi")) { model.acceptSuggestion(entry) }.buttonStyle(VerbButtonStyle(kind: .secondary, compact: true))
                    }
                }
            }
        }
    }
}
