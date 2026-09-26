# Contributing to Verb

Thanks for helping. This guide covers setup, where code goes, the conventions the codebase follows, and the checks a pull request needs. If you use a coding agent, point it at [AGENTS.md](AGENTS.md) too.

## Ground rules

These are what make Verb trustworthy. A change that breaks one of them won't be merged, however useful it is.

1. **Local by default.** No network request unless the user chose a remote provider *and* turned on **Allow remote processing**. `EndpointPolicy` and `HarnessPolicy` enforce this. Model downloads the user starts are the only exception.
2. **No telemetry.** No analytics, crash reporters, update pings or remote logging of any kind.
3. **Never lose the user's words.**
   - The raw transcript is saved before any rewriting.
   - A failed step keeps the original text.
   - A cancelled dictation can be restored.
   - A dictation that couldn't be pasted waits as the last dictation.
4. **The clipboard belongs to the user.** It is always given back after a paste. It is never overwritten when a paste can't happen.
5. **Secrets go in the Keychain** (`Secrets` in `Services.swift`). They never go in `settings.json`, in logs or in error messages.
6. **Nothing read from other apps is stored.** The text around the cursor and the typing memory stay in memory, for the duration of one dictation. Words you retype after a dictation wait as suggestions in memory; a word turned down is kept only as a digest.
7. **A writing model never changes meaning silently.** `CleanupGuard` stays on the path of every clean-up.
8. **Subscription CLIs stay sandboxed.**
   - No shell, and no text in `argv`.
   - Tools, MCP, hooks and web access are disabled.
   - There is no fallback to API keys or to another provider.

## Setup

**You need** an Apple Silicon Mac, macOS 14 or later, and Xcode with Swift 6.2+ and the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).

```sh
bash scripts/build.sh            # release/Verb.app
open release/Verb.app
swift test                       # 122 tests
```

- `scripts/build.sh` refuses to run while Verb is open. Quit it first with `osascript -e 'tell application id "app.verb.dictation" to quit'`.
- Every rebuild is signed ad hoc, so macOS can ask for Microphone and Accessibility again. If the Accessibility switch is on but Verb says it's off, remove Verb from the list and add the new build.
- Hotkeys and the microphone are global. **Don't run two full instances.** To look at the UI, use the snapshot renderer; to try flows, use the scripted checks. The renderer and the welcome check run from `.build/release/Verb` with a throwaway profile, with no microphone, hotkey or model; the notepad check and the field probe need the app bundle, through `open -n -g release/Verb.app --args …`.
- `--data-dir /tmp/verb-profile` runs the app on an isolated profile instead of your own data, with its own Keychain entries.

## Where code goes

| Target | Put here | Don't put here |
|---|---|---|
| `VerbCore` | Anything that can be a pure function: text rules, parsing, matching, formatting, policies, storage, settings. **Add tests.** | AppKit, SwiftUI, audio, Accessibility, processes |
| `VerbEngine` | Model runtimes, downloads, HTTP clients, child processes | UI |
| `Verb` | Views, the app model, macOS services (audio, hotkeys, Accessibility, pasteboard, Core Audio taps), diagnostics | Logic that could be tested in `VerbCore` |
| `VerbCheck` | Command-line access to the engines | App-only behaviour |

If a behaviour needs a heuristic, such as when to lowercase, when a word is a name, or whether a phrase is the wake phrase, write it in `VerbCore` with cases from real dictations in the tests.

## Conventions

### Swift

- **Match the surrounding code.** Its naming, compact style, comment density and idioms. Read the neighbouring functions before writing yours.
- **Comments say what something is for and why**, in plain sentences: a doc comment on types and on non-obvious members, a short line where the reason isn't visible in the code. Don't narrate what the code already says.
- The package builds in Swift 5 language mode. UI and the app model are `@MainActor`.
- **New dependencies need a discussion first.** The graph is MLX, MLX Audio Swift and the packages they bring.

### Settings

A new preference is an optional stored property with a computed accessor that supplies the default. That way, a settings file written without it still decodes with every other preference intact:

```swift
/// Turn the Mac's sound down while dictating. On unless turned off.
public var duck: Bool?
public var duckAudio: Bool {
    get { duck ?? true }
    set { duck = newValue }
}
```

Views bind to the accessor (`$model.settings.duckAudio`). `AppModel.persistSettings(old:)` is where a change takes effect.

### UI

- **Use the components and `Typeface` in `Theme.swift`, and the tokens in `DesignTokens.swift`:** `Palette`, `TypeSize`, `Space`, `Radius`, `Sizing`, `Motion`. No literal colours or sizes. To change a token, edit `Design/tokens.json` and run `python3 scripts/generate-tokens.py`. It regenerates the Swift and CSS and fails if a colour pair drops below its WCAG contrast minimum. Never edit `DesignTokens.swift` by hand.
- **Paper and ink.** Ink is the primary action colour, and a page has at most one primary button: the next thing to do. Red pencil (`Palette.accent`) is reserved for the brand, live recording, rubrics and links. New York (`Typeface.display`) is for titles and for the user's own words; SF (`Typeface.text`) is for everything else.
- **Accessibility.**
  - Icon-only controls get a label.
  - Buttons answer across at least `Sizing.controlMin` (44 pt), whatever they look like; `VerbButtonStyle` does it. The overlay's compact controls and segmented controls are sized to what surrounds them.
  - Status is never shown by colour alone.
  - Animations respect Reduce Motion.
  - The window works at its minimum size, 900 × 680.

### Words

- **Every string is written in both languages at the call site**, as `t("English", "Italiano")`. Write each one as a native speaker would, never word for word.
- **Messages from `VerbCore` and `VerbEngine` are English** and get translated in `Sources/Verb/Italian.swift`, as an exact entry or a pattern. Add the Italian when you add a message.
- **Voice.**
  - Short sentences, verb first.
  - Buttons say the action and its object: “Download the speech model”, “Add word”. Never “OK”, “Yes” or “Confirm”.
  - Sentence case: “Open at login”. Menu items follow the macOS title case: “Take the Tour”.
  - No em dashes. Use a full stop, a comma, or a middle dot `·` between side-by-side facts: “Mail · 23:41 · 21 words”.
  - Typographic quotes and apostrophes: “ ” ’.
  - Voice commands are written as said, in quotes: “Ehi Verb stop”.
  - No emoji and no brochure words (“powerful”, “seamless”). Say the concrete thing: “Audio stays on this Mac”.
  - In explanations Verb talks about itself in the third person (“Verb writes where the cursor is”). It uses the first person only in the status of work under way (“Writing it down”, “Trascrivo”).
  - An error says what happened, why, and what to do next, and reassures only when that's true: “The recording is saved. Retry from History.”
- **Docs describe the product as it is.** When behaviour changes, update the README in the same pull request. There are no version histories or release notes in the repository.

## Before you open a pull request

- [ ] `swift test` passes. Logic changes come with tests.
- [ ] `bash scripts/build.sh` succeeds and the app runs.
- [ ] **UI changes:** render the affected screens and attach them in light and dark, English and Italian, including the 900 × 680 minimum where layout is involved:
  ```sh
  .build/release/Verb --render-snapshots /tmp/renders --only page-home,welcome
  ```
  To cover a new screen or state, add it to `Snapshots.swift`. Time-dependent views need a frozen moment for renders: see `LevelMeter.preview` and `DemoVoice.frozen`.
- [ ] **Welcome, tour or notepad changes:** `--check-welcome FILE` and `--check-notepad FILE` pass.
- [ ] **Engine changes:** the relevant `verb-check` command runs (see the README).
- [ ] The README matches the new behaviour.

## Pull requests

- Keep each pull request to one change. Say what it does and why.
- Include screenshots for anything visible.
- Call out any privacy impact: new network access, a new permission, or more text read from other apps.
- Don't bump versions. Don't commit `release/`, `.build/`, model weights, recordings or personal data.

## Reporting bugs

Include:

- your Mac model and macOS version;
- the app and field where it happened, with its bundle ID if you know it;
- what the overlay or History said;
- steps to reproduce.

For insertion or spacing problems in a specific app, attach the output of:

```sh
open -n -g release/Verb.app --args --probe-fields /tmp/fields.txt
```

It records what each app exposes to Accessibility, as flags and sizes, with no text. Don't attach recordings or History entries unless you're happy to share what's in them.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
