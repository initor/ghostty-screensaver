# Ghostty Screensaver

A macOS screensaver that animates ASCII frames, originally inspired by [ghostty.org](https://ghostty.org/).

![Ghostty Screensaver Demo](assets/demo_1440.gif)

## Requirements

- **macOS 12 (Monterey)** or later.
- **Universal binary** — runs natively on Apple Silicon and on Intel Macs.

To verify the architecture of an installed copy:

```bash
lipo -archs ~/Library/Screen\ Savers/ghostty.saver/Contents/MacOS/ghostty
# Should print: x86_64 arm64
```

## Installation

### Option A: Download from Releases

1. Download `ghostty.saver.zip` from the [latest release](https://github.com/initor/ghostty-screensaver/releases) (it saves to `~/Downloads` by default).
2. Unzip the file to get `ghostty.saver`.
3. Open Terminal and run:

> [!IMPORTANT]
> **You must run this command or macOS will say the file is "damaged and can't be opened."**
> This is not a bug — macOS blocks all unsigned downloads with a misleading error.
> The command below removes that block. It assumes the file is in `~/Downloads`;
> change the path if you saved it elsewhere.

```bash
xattr -r -d com.apple.quarantine ~/Downloads/ghostty.saver
```

4. Double-click the `.saver` file and follow any prompts to install.
   - Alternatively, manually move it to `~/Library/Screen Savers/`.

### Option B: Build from Source

1. Clone this repository.
2. Open `ghostty.xcodeproj` in Xcode (16.2+ recommended).
3. **Use a Release build, not Debug.** Debug is unoptimized and single-arch only:
   - In Xcode: `Product → Archive`, then `Distribute Content → Built Products` to get a Release `.saver`.
   - Or from the command line:
     ```bash
     xcodebuild -project ghostty.xcodeproj \
                -scheme ghostty \
                -configuration Release \
                -derivedDataPath ./build \
                CODE_SIGNING_ALLOWED=NO
     codesign -s - --force ./build/Build/Products/Release/ghostty.saver
     ```
     (Ad-hoc signing is required so legacyScreenSaver can read the bundled frame files — see commit history for details.)
4. The `.saver` file lives at `./build/Build/Products/Release/ghostty.saver` (CLI build) or in your Xcode archive.
5. Double-click to install, or copy/drag into `~/Library/Screen Savers/`.
6. Select **Ghostty Screensaver** in System Settings → Screen Saver.

### Installation Issues & Troubleshooting

> "ghostty.saver is damaged and can't be opened"

This happens when macOS quarantine blocks an unsigned download. Remove the quarantine attribute:

```bash
xattr -r -d com.apple.quarantine ~/Downloads/ghostty.saver
```

Adjust the path if you unzipped it somewhere other than `~/Downloads`. Then double-click the `.saver` file again to install.

> "App cannot be opened because the developer cannot be verified"

macOS Gatekeeper may block the `.saver` file. To work around this:

1. System Settings (macOS Ventura or later):

- Open `System Settings → Privacy & Security`.
- Scroll down to the "Security" section. You should see a warning about "Ghostty.saver" being blocked.
- Click `"Open Anyway"` to allow installation.

2. Security & Privacy (macOS Monterey or earlier):

- Go to System Preferences → Security & Privacy → General.
- You might see a message that says "Ghostty.saver was blocked from opening because it is not from an identified developer."
- Click "Open Anyway" and confirm.

> [!NOTE]
> Once installed, if the new version of the screensaver doesn't **load** immediately, try:

- Rebooting your Mac, or
- Killing the `legacyScreenSaver` processes in Activity Monitor (search for "legacyScreenSaver" and force quit).

macOS should then pick up the newly installed `.saver` file.

## Development

### Project layout

```
ghostty-screensaver/
├── ghostty/
│   ├── ghosttyView.{h,m}             # ScreenSaverView subclass: lifecycle, animation, drawing
│   ├── GhosttyFrameLoader.{h,m}      # Bundle scan, regex parse, NSAttributedString build
│   └── static/animation_frames/       # 235 frame_NNN.txt files (the content)
├── ghostty.xcodeproj/                 # Xcode project (uses PBXFileSystemSynchronizedRootGroup)
├── .github/workflows/                 # CI (build) + release (tag-driven)
├── FRAMES.md                          # Frame file format specification
└── README.md                          # this file
```

Source is pure Objective-C with ARC enabled. Rendering goes through Core Text
(`CTFramesetter` + `CTFrame`); see commits in `git log -- ghostty/ghosttyView.m`
for the architectural history.

### Build & iterate

- **Cmd-B** in Xcode to build.
- **Cmd-R** runs the screensaver target inside Xcode's preview UI.
- For an end-to-end test, build Release, install the `.saver` into
  `~/Library/Screen Savers/`, and trigger the saver from System Settings.
  Note that **the `legacyScreenSaver` host caches loaded `.saver` bundles** —
  re-installing a new build often requires killing the host process:
  ```bash
  killall legacyScreenSaver 2>/dev/null
  ```
- **Logs:** the saver writes to the unified log subsystem `com.ghostty.screensaver`.
  Tail with:
  ```bash
  log stream --predicate 'subsystem == "com.ghostty.screensaver"'
  ```

### Adding new frames or colors

See [FRAMES.md](FRAMES.md) — covers the `frame_NNN.txt` filename rules,
encoding, the `<span class="b">…</span>` tag syntax (multi-line allowed,
nested not), and how to wire up an additional highlight color.

### Features

- Loads ASCII frames from `.txt` files in the screensaver's Resources folder.
- Parses `<span class="b">…</span>` as blue `(0,0,230)`, everything else is white `(215,215,215)`.
- Animates frames at 30 FPS.
- Frames are loaded once per process (`dispatch_once`) and shared across
  multi-display setups and the System Settings preview pane.

### Code review artifacts

The `.planning/review/` tree (gitignored, local only) contains a
deduplicated synthesis of a 24-reviewer parallel code review (12
craftsmanship/performance lenses + 12 benchmark/test-coverage lenses)
plus a live bench run captured from this codebase. See
`.planning/review/DASHBOARD.html` for the visual summary.

## Credits

Original ASCII frames from [ghostty.org](https://ghostty.org/) via the [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames) repository.

## License

MIT — see source headers.
