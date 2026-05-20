# ContextSnap

AI-friendly screenshot capture for macOS. Snap a region, see it float in the
corner of your screen, then drag it (or paste it) into whatever you're talking
to — terminals get the file path, chat apps get the image, no thinking required.

> Status: early prototype. macOS 12.3+. Built with Swift + SwiftUI + AppKit.

## Features

- **Global hotkey** — `⌃⇧⌘S` to capture a region using the native macOS
  selection UI.
- **Floating stack** — captures pile up in a translucent panel that floats
  above every space; close individual shots or clear the whole stack.
- **Smart drag / paste** — every shot is offered to receiving apps in
  multiple representations at once (file URL, PNG bytes, plain-text path), so
  the *target* picks the format it understands:
  - Terminals / Claude Code → plain-text path
  - iMessage, Slack, WeChat, Discord → image attachment
  - Preview / Notes / image editors → raw PNG
- **Archived to disk** — every shot saved under `~/Pictures/ContextSnap/`.

## Download

Grab the latest `.dmg` from the [Releases page](https://github.com/CPPAlien/ContextSnap/releases/latest).

1. Open the DMG, drag **ContextSnap.app** into **Applications**.
2. This build is **not yet notarized by Apple**, so macOS Gatekeeper will refuse
   to open it on first launch. Remove the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ContextSnap.app
   ```

3. Launch ContextSnap. On the first capture, macOS will ask for
   **Screen Recording** permission — grant it in *System Settings →
   Privacy & Security → Screen Recording*, then trigger the hotkey again.

> Why the `xattr` step? Apple's Developer Program ($99/year) is required to
> notarize apps so that Gatekeeper trusts them silently. This project hasn't
> enrolled yet; the command above is the official way to whitelist an
> un-notarized app you trust.

## Build from source

```bash
git clone https://github.com/CPPAlien/ContextSnap.git
cd ContextSnap
./Scripts/build-app.sh           # produces .build/release/ContextSnap.app
./Scripts/package-dmg.sh         # optional: build a distributable dmg into dist/
open .build/release/ContextSnap.app
```

The first launch will prompt for Screen Recording permission. Grant it in
System Settings → Privacy & Security → Screen Recording, then relaunch.

## Usage

- Press `⌃⇧⌘S` anywhere → drag-select a region → it appears in the floating
  stack.
- **Drag** a tile into any app to drop it (terminal, chat, editor, browser).
- **Click** a tile to copy it to the clipboard in all formats at once.
- **Hover** a tile and click the ✕ to remove it.
- Menu bar icon → `Clear Stack` wipes the overlay; `Quit` exits.

## Project layout

```
Sources/ContextSnap/
├── main.swift               # NSApplication bootstrap
├── AppDelegate.swift        # status item + hotkey wiring
├── Capture/
│   ├── ScreenCapturer.swift # shells out to /usr/sbin/screencapture -i
│   └── ShotStore.swift      # ~/Pictures/ContextSnap/clip-*.png
├── Models/
│   └── ShotStack.swift      # @MainActor ObservableObject
├── Overlay/
│   ├── OverlayPanelController.swift  # NSPanel hosting the SwiftUI view
│   ├── ShotStackView.swift
│   └── ShotTileView.swift   # drag source + close button
├── Clipboard/
│   └── MultiFormatPasteboard.swift   # multi-representation pasteboard
└── Hotkey/
    └── GlobalHotkey.swift   # Carbon RegisterEventHotKey wrapper
```

## License

MIT.
