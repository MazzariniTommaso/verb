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
swift build -c release --product Verb                        # just the binary, enough for renders and checks
swift test                                                   # 122 tests; all must pass
.build/release/Verb --render-snapshots DIR [--only a,b]      # every screen, EN/IT × light/dark, throwaway profile
.build/release/Verb --check-welcome FILE                     # welcome and tour, off screen, result written to FILE
open -n -g release/Verb.app --args --check-notepad FILE      # the floating notepad's window behaviour
python3 scripts/generate-tokens.py                           # after editing Design/tokens.json
osascript -e 'tell application id "app.verb.dictation" to quit'   # before rebuilding the bundle
```

## Map

| Where | What |
|---|---|
| `Sources/Verb/AppModel.swift` | The app's state machine and owner of everything: `begin` → `finish` → `run` (transcribe, rules, writing model, guard, fit, insert), voice activation, live preview. |
| `Sources/Verb/Hotkeys.swift` | The keyboard event tap for modifier-only bindings, Space and Escape. Carbon hot keys for bindings that include a key. |
| `Sources/Verb/TextInsertion.swift` | `TextTarget` capture, `FieldContext` (text around the cursor), the lazy pasteboard, clipboard restore, `⌘V`. |
| `Sources/Verb/Services.swift` | Recorder (AVAudioEngine), microphones, Keychain (`Secrets`), the private Ollama process. |
| `Sources/Verb/Onboarding.swift`, `Tour.swift` | The welcome and the tour. `WelcomeCheck.swift` is their scripted check. |
| `Sources/Verb/Theme.swift`, `DesignTokens.swift` | UI components and generated tokens. |
| `Sources/Verb/Localization.swift`, `Italian.swift` | `t("English", "Italiano")` and the translations of engine messages. |
| `Sources/Verb/Snapshots.swift` | The renderer with its seeded sample data. |
| `Sources/VerbCore/*` | Pure logic with tests: `TextRules`, `FieldText` (fitting and learning), `CleanupGuard`, `VoiceCommands`, `VoiceActivity`, `CodeSpeech`, `EnglishTerms`, `SnippetVariables`, `RichText`, `Notes`, `Storage`, `Models` (settings and records), `Harness` (provider policy). |
| `Sources/VerbEngine/*` | `LocalSpeech` (MLX), `SpeechPCM`, `ModelClient` (HTTP), `HarnessClient` and `CLIProcess` (subscription CLIs). |
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
- **Rebuilding the bundle replaces the ad-hoc signature**, and macOS may drop the Accessibility grant. Only the user can grant it again in System Settings, so say so if it matters.
- **Checks can't read SwiftUI's accessibility tree.** It is only built when an assistive app is running. Assert on model state or on small static hooks, the way `TourLayer.reached` and `WelcomeView.ticked` do, not on on-screen text.
- **Snapshot windows are off screen, so SwiftUI animations don't advance there.** Anything driven by time needs a frozen state for renders (`LevelMeter.preview`, `DemoVoice.frozen`). Otherwise the capture catches the start of an animation.
- **Renders add hairlines at the ends of the small overlay capsule**, an artefact of the capture method. The screen doesn't show them.
- **Accessibility calls into Verb's own process work.** The notepad and the practice sheet rely on them: a dictation goes straight to the focused `NoteEditing` view instead of through `⌘V`.
- **`swift test` runs both test bundles.** Engine tests use fixtures and need no models or network.
- **`scripts/build.sh` keeps bundled weights across rebuilds** and copies `Resources/Licenses` fresh each time. Weights and recordings never go into the repository.

## Done means

1. `swift test` passes, and `bash scripts/build.sh` succeeds.
2. For UI changes, you rendered the affected screens (light and dark, English and Italian, and 900 × 680 where layout matters) and looked at them.
3. For welcome, tour or notepad changes, the scripted checks pass.
4. The README still matches the behaviour, and nothing in the change mentions versions or history.
