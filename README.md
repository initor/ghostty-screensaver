<div align="center">

# Ghostty Screensaver

<sub>An unofficial macOS screensaver of [Ghostty](https://ghostty.org/)'s homepage ASCII animation</sub>

<br>

[![Build](https://github.com/initor/ghostty-screensaver/actions/workflows/build.yml/badge.svg)](https://github.com/initor/ghostty-screensaver/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/initor/ghostty-screensaver?style=flat&color=222)](https://github.com/initor/ghostty-screensaver/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/initor/ghostty-screensaver/total?style=flat&color=222)](https://github.com/initor/ghostty-screensaver/releases)
[![Platform](https://img.shields.io/badge/macOS-12%2B-222?style=flat)](#compatibility)
[![License](https://img.shields.io/badge/license-MIT-222?style=flat)](LICENSE)

<br>

<!-- Theme-aware hero per github.com/orgs/community/discussions/16925:
     dark mode shows the animated GIF; light mode shows a negated still
     so the artwork sits on a light background instead of pasting a
     stark black box onto white pages. -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/demo_1440.gif">
  <source media="(prefers-color-scheme: light)" srcset="assets/demo_light.png">
  <img
    alt="Ghostty screensaver — 235-frame ASCII ghost animation, white glyphs on black with periodic blue accents, looping on an idle macOS desktop."
    src="assets/demo_1440.gif"
    width="900">
</picture>

</div>

---

> **Unofficial fan project.** Not affiliated with, endorsed by, or sponsored by [Ghostty](https://ghostty.org/) or Mitchell Hashimoto. The 235 ASCII animation frames are reused from the public [ghostty-org/website](https://github.com/ghostty-org/website) repo under MIT — see [Acknowledgements](#acknowledgements).

A native macOS `.saver` bundle that loops [Ghostty](https://ghostty.org/)'s homepage 235-frame ASCII animation through Core Text. Universal binary, 30 Hz on AC, 15 Hz under Low Power Mode. Pure Objective-C — no Electron, no WebView, no daemons.

## Install

1. Download `ghostty.saver.zip` from the [latest release](https://github.com/initor/ghostty-screensaver/releases) and unzip it.
2. Double-click `ghostty.saver`. macOS opens **System Settings → Screen Saver** with **Ghostty Screensaver** ready to install.
3. If macOS prompts about an unidentified developer, open **System Settings → Privacy & Security**, scroll to *Security*, and click **Open Anyway**.

That's it. Verify the universal slice landed:

```bash
lipo -archs ~/Library/Screen\ Savers/ghostty.saver/Contents/MacOS/ghostty
# x86_64 arm64
```

<details>
<summary><b>"ghostty.saver is damaged and can't be opened"</b></summary>

Unsigned releases ship with a Gatekeeper quarantine flag. The file isn't damaged — strip the flag and re-open:

```bash
xattr -dr com.apple.quarantine ~/Downloads/ghostty.saver
```

Adjust the path if you unzipped elsewhere. Signed/notarized releases skip this step. See the [Why is it unsigned?](#faq) FAQ entry below.
</details>

<details>
<summary><b>New build doesn't show up after re-installing</b></summary>

`legacyScreenSaver` caches `.saver` bundles per process. Force a reload:

```bash
killall legacyScreenSaver 2>/dev/null
```
</details>

> Building from source? See [Develop](#develop).

## Compatibility

|                              | Apple Silicon (arm64) | Intel (x86_64)             |
| ---------------------------- | --------------------- | -------------------------- |
| **macOS 12** Monterey (min)  | Supported             | Supported                  |
| **macOS 13** Ventura         | Supported             | Supported                  |
| **macOS 14** Sonoma          | Supported             | Supported                  |
| **macOS 15** Sequoia         | CI-built, smoke-tested | CI-built (universal slice) |
| **macOS 26** Tahoe           | UAT'd                 | Not tested                 |

Single universal `.saver` (`ARCHS = arm64 x86_64`, `MACOSX_DEPLOYMENT_TARGET = 12.0`). No per-architecture code paths.

## How it works

`GhosttyView` is an `NSScreenSaverView` subclass loaded by macOS's `legacyScreenSaver` host. Each tick it builds a fresh `CTFramesetter` + `CTFrame` from the current pre-attributed frame and releases both before returning — Core Text instead of `NSLayoutManager` because the latter's caches grew unboundedly under per-frame `setAttributedString:` swaps (~1.6 KB/frame, no plateau over 7050 frames on macOS 26). The 235-element `NSAttributedString` array loads once per process via `dispatch_once`, shared across every `NSScreen`, the System Settings preview pane, and view re-instantiations. The view is layer-backed (`wantsLayer = YES`) so the per-tick black background is a `CALayer.backgroundColor` GPU composite, not a CPU `NSRectFill`.

- 30 Hz on AC, 15 Hz in Low Power Mode (via `NSProcessInfoPowerStateDidChangeNotification`).
- Frame array singleton — multi-display + Settings preview share one ~2.7 MB load.
- `drawRect:` is allocation-free in steady state; `(usedSize, origin)` is cached per frame index.
- `os_signpost` Points-of-Interest are always on — Instruments-ready, zero cost when detached.

## FAQ

> **Why does macOS say the file is "damaged" or "from an unidentified developer"?**

The release `.zip` is unsigned (no Apple Developer ID), so macOS quarantines it on download and shows a misleading error. Run `xattr -dr com.apple.quarantine ~/Downloads/ghostty.saver` to clear the flag, or click **Open Anyway** in *System Settings → Privacy & Security* after the first failed open. Signed/notarized builds skip both prompts; the GitHub Actions release workflow produces one automatically when an Apple cert is configured.

> **My new build doesn't show up after re-installing — what gives?**

`legacyScreenSaver` caches `.saver` bundles per process and won't pick up a fresh install until it restarts. Run `killall legacyScreenSaver` (or reboot) and re-open *System Settings → Screen Saver*.

> **Does it work on multiple displays / external monitors?**

Yes. macOS instantiates one `GhosttyView` per active screen; the 235-frame array is a process singleton (`dispatch_once`), so multi-display setups share a single ~2.7 MB load instead of paying it per screen. All displays animate independently at the same rate.

> **What's the battery / CPU impact?**

Negligible on Apple Silicon, modest on Intel. The view auto-throttles to 15 Hz under Low Power Mode, uses a layer-backed view so WindowServer composites on the GPU, and `drawRect:` is allocation-free in steady state. To be extra-conservative on battery, toggle Low Power Mode.

> **How do I customize the colors or supply my own ASCII art?**

See [FRAMES.md](FRAMES.md) for filename rules, encoding, span syntax, and adding a highlight color. Drop new frames into `ghostty/static/animation_frames/` and rebuild — no code changes needed for content.

> **How do I uninstall?**

```bash
rm -rf ~/Library/Screen\ Savers/ghostty.saver
killall legacyScreenSaver 2>/dev/null
```

That's the whole footprint — no launch agents, no preferences pane, no `~/Library/Application Support` directory. (If you installed under `/Library/Screen Savers/` for all users, use `sudo` and that path instead.)

## Develop

```bash
git clone https://github.com/initor/ghostty-screensaver.git
cd ghostty-screensaver
open ghostty.xcodeproj   # Xcode 16.2+
```

Press <kbd>⌘ R</kbd> to run the saver in Xcode's preview pane, or <kbd>⌘ B</kbd> to build without launching. For an end-to-end test against the real `legacyScreenSaver` host, do a Release build (`Product → Archive`, or `xcodebuild -configuration Release`), copy `ghostty.saver` into `~/Library/Screen Savers/`, and `killall legacyScreenSaver`.

### Project layout

```
ghostty/
├── GhosttyView.{h,m}            ScreenSaverView subclass — lifecycle, drawing, LPM
├── GhosttyFrameLoader.{h,m}     Bundle scan, span parser, dispatch_once cache
└── static/animation_frames/     235 frame_NNN.txt files (the content)
ghostty.xcodeproj/               PBXFileSystemSynchronizedRootGroup — auto-includes new files
.github/workflows/               CI: universal Release build on PR; release on tag
FRAMES.md                        Frame file format spec
LICENSE                          MIT (wrapper) + upstream MIT (frames)
```

Pure Objective-C, ARC. Rendering uses Core Text. For history: `git log --follow -- ghostty/GhosttyView.m`.

### Logs

```bash
log stream --predicate 'subsystem == "com.initor.ghostty-screensaver"'
```

`os_signpost` intervals (`FrameLoad`, `DrawFrame`, `Tick`) appear in **Instruments → Points of Interest** with no extra build flags.

### Releasing

Push a `vX.Y.Z` tag on `main`; `.github/workflows/release.yml` builds a universal `.saver`, signs and notarizes if `DEVELOPER_ID_*` / `APPLE_*` secrets are configured, otherwise ad-hoc-signs and ships unsigned with quarantine instructions baked into the release notes.

## Contributing

PRs welcome. For new frames, see [FRAMES.md](FRAMES.md) — by submitting a frame file, you affirm you authored it, or that it is sourced from a repo whose license permits redistribution under MIT (cite the source in the PR). Wrapper-code contributions are MIT, inbound = outbound.

## Acknowledgements

The 235 ASCII animation frames in `ghostty/static/animation_frames/` were created by the [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames) contributors and are reused here with attribution under MIT (Copyright (c) 2024 Ghostty). All artistic credit for the animation belongs to the upstream authors. The wrapper around them — `ScreenSaverView` host, frame loader, build pipeline — is original work.

If you are an upstream contributor and prefer different attribution wording, or want the frames removed, please open an issue.

## License

MIT — see [LICENSE](LICENSE). The frame corpus retains its upstream MIT (Copyright (c) 2024 Ghostty); both notices are reproduced in `LICENSE`.
