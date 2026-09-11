# ContextSnap

**The missing screenshot tool for Claude Code.** Snap a region, paste it
straight into Claude Code as a file path — and into WeChat, Slack or iMessage
as a real image — from the *same* capture. No saving, no re-uploading, no
"why did it paste a giant base64 blob into my terminal?"

> macOS 12.3+ · Swift + SwiftUI + AppKit · MIT · ~2 MB

## Why this exists

Claude Code, Codex CLI, and every other terminal-based AI tool want an
**image path on disk**, not pixels — paste pixels into a terminal and you get
nonsense. Chat apps (WeChat, Slack, iMessage, Discord) want the **opposite**:
a real inline image, not a path. macOS's built-in screenshot tool gives you
*one* representation at a time, and you end up saving to Desktop, finding the
file, and dragging it in by hand.

ContextSnap puts **every** representation on the clipboard at once. The app
you paste into picks the one it understands:

| You're pasting into… | What ContextSnap delivers |
| --- | --- |
| **Claude Code / Codex / any terminal** | The plain-text **file path** — Claude reads the image from disk |
| **WeChat / Slack / iMessage / Discord** | The actual **image attachment** |
| **Preview / Notes / Figma / image editors** | Raw **PNG pixels** |
| **Finder / file uploaders / `<input type=file>`** | The **file reference** |

One capture. One paste. Always the right format.

## Features

- **Global hotkey** — `⇧⌘S` (rebindable) to capture a region with the native
  macOS selection UI.
- **Floating stack** — captures pile up in a translucent panel that floats
  above every Space, so you can queue up multiple shots before pasting.
- **Multi-format clipboard** — every shot is written to the pasteboard as
  file URL + PNG bytes + plain-text path simultaneously.
- **Drag or paste** — drag a tile straight into any app, or just `⌘V`.
- **Ask AI about the shot** — right after selecting a region, hit *Ask AI* and
  a chat window opens on the capture. Answers come from the **Claude Code** or
  **Codex** CLI already installed on your Mac, so there is no extra API key
  and no upload — see [Ask AI](#ask-ai-claude-or-codex).
- **Archived to disk** — every shot lives at `~/Pictures/ContextSnap/`, so
  Claude Code (and your future self) can still find it later.
- **Stays out of your way** — menu-bar only, no Dock icon, no window
  furniture. Stack overlay can be hidden via Settings if you only want the
  clipboard behavior.

## Install

### Homebrew (recommended)

```bash
brew install --cask CPPAlien/contextsnap/contextsnap
```

Homebrew downloads outside Safari's quarantine, so the app launches on
first run without the `xattr` step described below.

### Manual `.dmg`

Grab the latest `.dmg` from the
[Releases page](https://github.com/CPPAlien/ContextSnap/releases/latest).

1. Open the DMG and drag **ContextSnap.app** into **Applications**.
2. This build isn't notarized yet, so macOS Gatekeeper will refuse to open it
   on first launch. Remove the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ContextSnap.app
   ```

3. Launch ContextSnap. On the first capture, grant **Screen Recording**
   permission in *System Settings → Privacy & Security → Screen Recording*,
   then trigger the hotkey again.
4. Optional — for the *Ask AI* chat, install a CLI agent
   (`npm i -g @anthropic-ai/claude-code` and/or `npm i -g @openai/codex`) and
   sign in to it once in a terminal. Everything else works without one.

> Why the `xattr` step? Notarization requires Apple's $99/year Developer
> Program; this project hasn't enrolled yet. The command above is the
> official way to trust an un-notarized app you downloaded yourself.

## Ask AI (Claude or Codex)

The *Ask AI* button on the selection toolbar opens a chat window anchored to
the region you just captured. It shells out to a CLI agent you already have,
running it in a login shell so `nvm` / Homebrew / `~/.local/bin` installs
resolve even though the app is launched by launchd:

| Agent | Needs | How it is called |
| --- | --- | --- |
| **Claude** (default) | [Claude Code](https://claude.com/claude-code) — `npm i -g @anthropic-ai/claude-code` | `claude -p … --allowedTools Read`, resumed per turn so the screenshot stays in context |
| **Codex** | [Codex CLI](https://developers.openai.com/codex/cli) — `npm i -g @openai/codex` or `brew install codex` | `codex exec --image <png> …`, continued with `codex exec resume <thread>` |

Whichever ones are installed are detected at launch. When both are there, the
chat header shows a **Switch to Codex / Switch to Claude** chip — switching
starts a fresh agent session while the transcript on screen stays put, and the
choice is remembered for the next window. If a CLI lives somewhere your shell
profile doesn't add to `PATH`, set an explicit command in *Settings → Ask AI
commands*.

In the chat window you can also:

- **keep typing while the agent answers** — the composer never locks up;
- **copy one reply** — hover a reply, hit the copy button on its right;
- **save the whole conversation** — the ⤓ button in the header writes a
  Markdown transcript wherever you point it;
- **read the math** — LaTeX that agents emit (`$v_i = \omega \times X_i$`)
  is rendered as Unicode (`vᵢ = ω × Xᵢ`) instead of raw markup.

## Use it

1. Press `⇧⌘S` anywhere → drag-select a region.
2. The shot appears in the floating stack (top-right corner).
3. Switch to Claude Code → `⌘V` → Claude sees the image path and reads it.
4. Or switch to WeChat → `⌘V` → an actual image attachment appears.
5. Or **drag** the tile straight into any app for the same result.

The menu-bar icon exposes *Clear Stack*, *Settings…* (hotkey + save folder +
show/hide the stack), and *Quit*.

## Build from source

```bash
git clone https://github.com/CPPAlien/ContextSnap.git
cd ContextSnap
./Scripts/build-app.sh           # → .build/release/ContextSnap.app
./Scripts/package-dmg.sh         # → dist/ContextSnap-<version>.dmg
open .build/release/ContextSnap.app
```

## Project layout

```
Sources/ContextSnap/
├── AppDelegate.swift                # menu-bar + hotkey wiring
├── Capture/SelectionOverlay.swift   # region picker + capture / Ask AI toolbar
├── Capture/ScreenCapturer.swift     # ScreenCaptureKit region grab
├── Capture/ShotStore.swift          # ~/Pictures/ContextSnap/clip-*.png
├── Clipboard/MultiFormatPasteboard  # the heart of it — multi-rep clipboard
├── Hotkey/GlobalHotkey.swift        # Carbon RegisterEventHotKey
├── AI/AIBackend.swift               # Claude / Codex selection + CLI detection
├── AI/ClaudeCLI.swift               # `claude -p` driver (JSON output, --resume)
├── AI/CodexCLI.swift                # `codex exec` driver (--image, resume)
├── AI/AIChatView.swift              # chat window: switch agent, copy, export
├── AI/MarkdownView.swift            # block-level Markdown for replies
├── AI/MathText.swift                # LaTeX → Unicode for inline math
├── Overlay/                         # SwiftUI floating stack
└── Settings/                        # hotkey + save dir + AI commands
```

## License

MIT.
