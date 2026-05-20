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
- **Archived to disk** — every shot lives at `~/Pictures/ContextSnap/`, so
  Claude Code (and your future self) can still find it later.
- **Stays out of your way** — menu-bar only, no Dock icon, no window
  furniture. Stack overlay can be hidden via Settings if you only want the
  clipboard behavior.

## Download

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

> Why the `xattr` step? Notarization requires Apple's $99/year Developer
> Program; this project hasn't enrolled yet. The command above is the
> official way to trust an un-notarized app you downloaded yourself.

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
├── Capture/ScreenCapturer.swift     # /usr/sbin/screencapture -i wrapper
├── Capture/ShotStore.swift          # ~/Pictures/ContextSnap/clip-*.png
├── Clipboard/MultiFormatPasteboard  # the heart of it — multi-rep clipboard
├── Hotkey/GlobalHotkey.swift        # Carbon RegisterEventHotKey
├── Overlay/                         # SwiftUI floating stack
└── Settings/                        # hotkey + save dir + visibility
```

## License

MIT.
