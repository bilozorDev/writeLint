# Write Lint

A macOS menu-bar app that polishes text — fixes typos, punctuation, capitalization, and minor grammar — using Apple's on-device Foundation Models. Everything runs locally; no text leaves your Mac.

## What it does

Press a global hotkey, type or paste, hit `⌘⏎`, and Write Lint cleans up mechanical errors while preserving your voice and meaning. It's tuned for the kind of text you bang out in Slack messages or ticket updates — short, casual, full of typos.

## Features

- **On-device polishing** via Apple Intelligence (`FoundationModels`). Nothing is sent to a server.
- **Word-level diff** — accept, reject, or copy with one keystroke.
- **Hallucination guards** — the model is constrained from expanding acronyms (`SOP` stays `SOP`), inventing connecting words, or rewriting sentences for "fluency".
- **Custom global hotkey** — default `⌘⇧L`, configurable in Settings.
- **Recent history** — last 10 prompts, stored locally.
- **Advanced mode** — see and edit the exact prompt sent to the model. One-click revert to factory default.

## Requirements

- macOS 26.0 (Tahoe) or later
- Apple Intelligence enabled on a supported Apple Silicon Mac
- Xcode 26 to build from source

## Build & run

```bash
git clone https://github.com/bilozorDev/writeLint.git
cd writeLint
open Linter/Linter.xcodeproj
```

Then ⌘R in Xcode. The app installs as a menu-bar item (sparkle icon). There is no pre-built release yet — build from source.

## Usage

| Action | Shortcut |
|---|---|
| Summon panel | `⌘⇧L` (configurable) |
| Polish text | `⌘⏎` |
| Accept polished result | `⌘⏎` again |
| Reject result / dismiss | `Esc` |
| Recent history | `⌘H` |
| Settings | gear icon (top-right of the panel) |

## Privacy

All polishing happens on-device through Apple Intelligence. Your text never leaves the Mac. The prompt and recent history are stored in macOS `UserDefaults` (plain text, per-user, local).

## License

[MIT](LICENSE) © 2026 Alex Bilozor
