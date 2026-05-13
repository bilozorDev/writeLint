# Write Lint

_On-device proofreader._

A macOS menu-bar app that polishes text — fixes typos, punctuation, capitalization, and minor grammar. Uses Apple's on-device Foundation Models by default, with optional Claude and OpenAI backends if you supply your own API key.

## What it does

Press a global hotkey, type or paste, hit `⌘⏎`, and Write Lint cleans up mechanical errors while preserving your voice and meaning. It's tuned for the kind of text you bang out in Slack messages or ticket updates — short, casual, full of typos.

## Features

- **On-device polishing** via Apple Intelligence (`FoundationModels`) — the default backend; your text stays on the Mac.
- **Optional cloud backends** — Claude or OpenAI, each with a user-supplied API key stored in macOS Keychain. Off until you add a key.
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

The default Apple Intelligence backend runs entirely on-device — your text never leaves the Mac. If you switch to Claude or OpenAI in Settings, the chunk being polished is sent over HTTPS to that provider's API (Anthropic or OpenAI) under your own API key, subject to their privacy policies. API keys live in macOS Keychain. Prompts and recent history are stored in `UserDefaults` (plain text, per-user, local).

## License

[MIT](LICENSE) © 2026 Alex Bilozor
