# AGENTS.md

Instructions for coding agents working in this repository. People should read [CONTRIBUTING.md](CONTRIBUTING.md); everything in it applies to agents too. This file adds what an agent needs to work without surprises.

## The project

Verb is a native macOS dictation app, a SwiftPM package with no Xcode project:

- **What it does:** hold fn, speak, and the text is inserted at the cursor in whatever app is in front.
- **Speech** runs on the Mac with MLX (Parakeet v3 or Qwen3-ASR).
- **Clean-up** goes through deterministic rules, then optionally a writing model: local Ollama, an OpenAI-compatible endpoint, or a sandboxed subscription CLI (Claude Code, Codex, Cursor, Gemini, Copilot).
- **Interface:** SwiftUI and AppKit, in English and Italian, light and dark.

## Commands

```sh
bash scripts/build.sh                                        # release/Verb.app; refuses while Verb runs
bash scripts/package.sh                                      # release/Verb.dmg to share, without speech weights
VERB_SIGN_IDENTITY=… VERB_NOTARY_PROFILE=… bash scripts/package.sh   # the same, signed with a Developer ID and notarized
swift build -c release --product Verb                        # just the binary, enough for renders and checks
swift test                                                   # 240 tests; all must pass
.build/release/Verb --render-snapshots DIR [--only a,b]      # every screen, EN/IT × light/dark, throwaway profile
.build/release/Verb --check-welcome FILE                     # welcome and tour, off screen, result written to FILE
.build/release/Verb --check-window FILE                      # the windows' smallest and largest sizes, in invisible windows
open -n -g release/Verb.app --args --check-notepad FILE      # the floating notepad's window behaviour
python3 scripts/generate-tokens.py                           # after editing Design/tokens.json
python3 scripts/fetch-speech-benchmark.py                    # the multilingual speech set, into ~/Library/Caches/Verb
.build/release/verb-check speech-bench MANIFEST Benchmarks/speech-models.json RESULTS.jsonl   # then speech-bench-report RESULTS.jsonl
.build/release/verb-check memory MODEL_ROOT AUDIO [MODEL]                  # memory with the speech model loaded, used and let go
.build/release/verb-check microphone [DEVICE_UID|system] [SECONDS]        # a microphone opened as Verb does; asks for microphone access
.build/release/verb-check ahead MODEL_ROOT AUDIO [MODEL]                   # part-by-part transcription against the whole: must give the same text
.build/release/verb-check ask TEXT                                         # a request, as the edit keys take it with nothing selected; needs Verb's Ollama
osascript -e 'tell application id "app.verb.dictation" to quit'   # before rebuilding the bundle
```

## Map

| Where | What |
|---|---|
| `Sources/Verb/AppModel.swift` | The app's state machine and owner of everything: `begin` → `finish` → `run` (transcribe, rules, writing model, guard, fit, insert), voice activation, live preview. |
| `Sources/Verb/Hotkeys.swift` | The keyboard event tap for modifier-only bindings, Space and Escape. Carbon hot keys for bindings that include a key. |
| `Sources/Verb/TextInsertion.swift` | `TextTarget` capture, `FieldContext` (text around the cursor), the lazy pasteboard, clipboard restore, `⌘V`. |
| `Sources/Verb/Services.swift` | Recorder (the dictation's microphone, its 16 kHz stream and file), Keychain (`Secrets`), the private Ollama process. |
| `Sources/Verb/MeetingRecorder.swift`, `NotesModel.swift` | Meetings: microphone and system audio (a Core Audio process tap) on two tracks, their watchdog, and the notes written from them. |
| `Sources/Verb/SettingsView.swift` | Settings in nine pages (`SettingsTab`, `model.settingsTab` opens one). Each row says what it does in one line; more goes in its `.help`. |
| `Sources/Verb/MicrophoneTestViews.swift` | Settings → Audio → Test the microphones: each one opened for a few seconds, and the verdict. |
| `Sources/Verb/AskFlow.swift`, `AssistantModel.swift` | The edit keys with nothing selected: actions (open, find, search, dictionary, remember, meetings) and answers or drafts from the writing model; the answer card's state; the parts of a long recording written while it records (`TranscriptAhead`); the site in a browser (`SiteReader`); the window's text for a request (`ScreenText`); which apps use the microphone (`MicrophoneUsers`), for calls. |
| `Sources/Verb/OverlayParts.swift`, `NotchOverlay.swift`, `OverlayStyles.swift` | The overlay. `OverlayParts` holds what every style shares: the facts read from the model, the symbols, the voice dots, the controls, and what it says once it opens (the words, a message, a choice, the box with a dictation that found no field, the box with an answer). `NotchOverlay` draws them at the notch; `OverlayStyles` at the bottom, in the Classic, Pill, Voice, Dot and Bar styles. |
| `Sources/Verb/Coach.swift`, `WelcomeExtras.swift` | The first dictation guided in an app; the welcome's microphone check, speed test and app choice. |
| `Sources/Verb/MeetingViews.swift`, `ReportView.swift` | Settings → Meetings and the notes typed during a meeting; Report a problem. |
| `Sources/Verb/Onboarding.swift`, `Tour.swift` | The welcome and the tour. `WelcomeCheck.swift` is their scripted check. |
| `Sources/Verb/Theme.swift`, `DesignTokens.swift` | UI components and generated tokens. |
| `Sources/Verb/Localization.swift`, `Italian.swift` | `t("English", "Italiano")` and the translations of engine messages. |
| `Sources/Verb/Snapshots.swift` | The renderer with its seeded sample data. |
| `Sources/VerbCore/*` | Pure logic with tests: `TextRules`, `SpokenPunctuation`, `FieldText` (fitting and learning), `FieldIdentity` (is the field still the one the dictation was for), `InsertionPolicy`, `MicrophoneChoice` (the kinds of microphone, their order, how often one restarts, what a test heard), `CleanupGuard`, `VoiceCommands`, `VoiceActivity`, `CodeSpeech`, `EnglishTerms`, `SnippetVariables`, `RichText`, `Notes`, `Storage`, `LibraryTransfer` (CSV and JSON), `Models` (settings and records), `Harness` (provider policy), `Assistant` (what a request asks for, and its prompt, with the questions before it), `OverlayScene` (what the overlay shows in every situation, the voice dots, the room beside the notch), `VocabularyMatch` (sound-alike corrections, the entries a text needs, recurring names), `Places` (sites, kinds of place, how lists paste in each app), `TextShapes` (spelled letters, the chat style), `Coaching` (hints of the first days, typing speed, the week), `MeetingKinds` (kinds of notes, calls noticed), `Diagnostics` (the problem report), `Layout` (the windows' limits on a screen, a page's sizes, margins and columns as the window grows, the window's buttons and the icon sidebar, the notch style's island on a screen with or without a notch). |
| `Sources/VerbEngine/*` | `LocalSpeech` (MLX), `SpeechModels` (any MLX speech model from a folder, and its installer), `SpeechPCM`, `Microphone` (devices and `MicrophoneInput`, one device read through its own input unit), `ModelClient` (HTTP), `HarnessClient` and `CLIProcess` (subscription CLIs). |
| `Sources/VerbCore/Speech*.swift`, `SpokenNumbers.swift` | Speech model families and their files (`SpeechArchitecture`), benchmark scoring, reports and picks. |
| `Sources/VerbCheck/SpeechBench.swift`, `Benchmarks/speech-models.json` | The speech benchmark commands and the candidate models. |
| `Tests/` | `VerbCoreTests`, `VerbEngineTests`, and `Fixtures/` (audio, a fake endpoint). |

## Rules

- **Keep the ground rules in CONTRIBUTING.md intact.** In short:
  - local by default;
  - no telemetry;
  - never lose words;
  - the clipboard is always restored;
  - secrets in the Keychain;
  - nothing read from other apps is stored;
  - `CleanupGuard` on every clean-up;
  - sandboxed CLIs.
- **Put logic in `VerbCore` with tests**, and keep views thin.
- **Every UI string is bilingual**, as `t("English", "Italiano")`. Engine and core messages are English, translated in `Italian.swift`. Follow the voice rules in CONTRIBUTING.md: short, verb first, no em dashes, typographic quotes, no emoji.
- **Use the tokens and components.** No literal colours or sizes, and never edit `DesignTokens.swift`.
- **New settings are optional stored properties with a defaulting accessor**, so existing settings files keep decoding.
- **Docs describe the product as it is:** no version numbers, release history or “previously” in code comments, UI text or Markdown. Update the README in the same change when behaviour changes.
- **Match the surrounding code:** naming, density, comment style. Comments explain purpose and reasons, not mechanics.

## Gotchas

- **Don't touch the user's data.** `~/Library/Application Support/Verb` holds their history, recordings and notes. Use `--data-dir`, the snapshot renderer or the checks, which create and delete their own profiles.
- **Don't launch a second full instance of Verb.** Hotkeys, the event tap and the microphone are system-wide and would clash with the running app. Renders and checks build `AppModel(services: false)` and are safe.
- **Rebuilding the bundle replaces the ad-hoc signature**, and macOS may drop the Accessibility grant. Only the user can grant it again in System Settings, so say so if it matters. Builds signed with `VERB_SIGN_IDENTITY` keep it.
- **Checks can't read SwiftUI's accessibility tree.** It is only built when an assistive app is running. Assert on model state or on small static hooks, the way `TourLayer.reached` and `WelcomeView.ticked` do, not on on-screen text.
- **Snapshot windows are off screen, so SwiftUI animations don't advance there.** Anything driven by time needs a frozen state for renders (`LevelMeter.preview`, `DemoVoice.frozen`). Otherwise the capture catches the start of an animation.
- **Renders add hairlines at the ends of the small overlay capsule**, an artefact of the capture method. The screen doesn't show them.
- **Verb's own shortcuts linger in the modifier flags.** After a posted ⌘C or ⌘V, `CGEventSource.flagsState` can report ⌘ held until a real key clears it. Ask whether the user holds a key with `TextInserter.modifierKeysDown`, which reads the keys themselves, and post shortcuts through `postCommand`, which releases ⌘.
- **Accessibility calls into Verb's own process work.** The notepad and the practice sheet rely on them: a dictation goes straight to the focused `NoteEditing` view instead of through `⌘V`.
- **Don't read the microphone through AVAudioEngine.** Its input opens the system's default input together with the default output, which switches Bluetooth headphones to call quality, and after a change of device it reports the previous format. The Objective-C exceptions it then raises are swallowed by AppKit inside a Swift task and crash the app later, at an unrelated click. Use `MicrophoneInput`.
- **`verb-check microphone` needs microphone access** for whatever runs it, so macOS asks once. Watch Core Audio at the same time with `/usr/bin/log stream --level debug --predicate 'process == "verb-check"'`: in zsh, a bare `log` is a builtin.
- **`swift test` runs both test bundles.** Engine tests use fixtures and need no models or network.
- **ImageRenderer draws no AppKit-backed views**: buttons with Verb's styles, scroll views, text editors come out as a yellow placeholder. Render those screens with the snapshot renderer's `save`, which captures a window, not `draw`.
- **The overlay shows a scene, not a style's own states.** `OverlayScene.of` decides from plain facts what goes on the left (`lead`), on the right (`trail`) and below or above (`body`); the styles only draw it. Beside the notch and on a closed capsule there are no words, only symbols, numbers and keys: a new state gets a symbol, and its sentence goes in the body. Add the rule to `OverlayScene` with a test before drawing it.
- **The notch style draws on black in both themes**, with its own tokens (`surfaceNotch`, `textOnNotch`, `accentOnNotch`). Its panel sits at the status bar's level with a dark appearance; its pieces read `onIsland` and take their colours from `OverlayInk`.
- **Closed, the island never covers the menus of the app in front.** `AppDelegate.measureMenuRoom` reads where they end with Accessibility when an app comes to the front, and `MenuRoom` moves the left symbol to the right when it doesn't fit. Open, it covers the menu bar for as long as it lasts.
- **The island measures the screen it is on** (`NSScreen.island`): the notch from the free areas beside it, or none, as on an external display, where it hangs from the top edge. Renders show it on a MacBook's notch, on a display without a menu bar (`-plain`) and on one with a menu bar (`-bar`), and with menus up to the notch (`-crowded`).
- **A window's limits live in its root view's frame.** An `NSHostingController` sets the window's smallest and largest sizes at every layout: with `sizingOptions = []` it sets them to none, so limits set on the window vanish. Give the window's root view `.frame(limits:)`, set `sizingOptions = [.minSize, .maxSize]`, and `safeAreaRegions = []` where the view runs under the title bar, or the title bar's height is added to both. `--check-window` proves them.
- **Pages read their layout from `\.pageLayout`**, which `MainView` sets from the room beside the sidebar. Use `PageScroll(cap:)` and `layout.margin`, never `Space.page` directly, and anchor columns at the leading edge. The sidebar's icon rail takes its width from the window's buttons as `AppDelegate.measureWindowButtons` finds them; renders draw them at the same place (`WindowChrome`).
- **Read a window's width in the same layout pass**, with a `GeometryReader`, as `MainView` and `NotesBrowser` do. A width set later from `onGeometryChange` lays out one frame at the wrong width: renders catch it, and that frame can need more room than the window has.
- **What a request reads on screen stays on the Mac.** `ScreenText` and the text near the cursor go only to a writing model on this Mac (`writingStaysOnMac`); a site's address is used during the dictation and never stored.
- **`scripts/build.sh` keeps bundled weights across rebuilds** and copies `Resources/Licenses` fresh each time. Weights and recordings never go into the repository.
- **Benchmark clips and models live in `~/Library/Caches/Verb`.** They take gigabytes and downloading them needs the user's go-ahead. Leaderboard numbers come from data-centre GPUs, so speed only counts when measured on a Mac.

## Done means

1. `swift test` passes, and `bash scripts/build.sh` succeeds.
2. For UI changes, you rendered the affected screens (light and dark, English and Italian, and the smallest window, 720 × 560, where layout matters) and looked at them.
3. For welcome, tour, notepad or window-size changes, the scripted checks pass.
4. The README still matches the behaviour, and nothing in the change mentions versions or history.
