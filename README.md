<div align="center">

# Ghostty Screensaver

<sub>An unofficial macOS screensaver of [Ghostty](https://ghostty.org/)'s homepage ASCII animation</sub>

<br>

[![Build](https://github.com/initor/ghostty-screensaver/actions/workflows/build.yml/badge.svg)](https://github.com/initor/ghostty-screensaver/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/initor/ghostty-screensaver?style=flat&color=222)](https://github.com/initor/ghostty-screensaver/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/initor/ghostty-screensaver/total?style=flat&color=222)](https://github.com/initor/ghostty-screensaver/releases)
[![Platform](https://img.shields.io/badge/macOS-12%2B-222?style=flat)](#install)
[![License](https://img.shields.io/badge/license-MIT-222?style=flat)](LICENSE)

<br>

<img
  alt="Ghostty screensaver: the ASCII ghost animation, light glyphs on black with a blue halo, looping on an idle macOS desktop."
  src="assets/demo_1440.gif"
  width="900">

</div>

---

> **Unofficial fan project.** Not affiliated with, endorsed by, or sponsored by [Ghostty](https://ghostty.org/) or Mitchell Hashimoto. The 235 animation frames come from the public [ghostty-org/website](https://github.com/ghostty-org/website) repo under MIT. See [Acknowledgements](#acknowledgements).

The ghost animation from [ghostty.org](https://ghostty.org/), running as a real macOS screen saver. Light on the battery, and nothing else runs in the background.

## Install

1. Download [`ghostty.saver.zip`](https://github.com/initor/ghostty-screensaver/releases/latest/download/ghostty.saver.zip) and unzip it. Safari unzips it for you. Release notes are on the [latest release](https://github.com/initor/ghostty-screensaver/releases/latest) page.
2. Clear the download flag. Open Terminal (press <kbd>⌘ Space</kbd>, type `Terminal`, press Return), paste this line, and press Return:

   ```bash
   xattr -d -r com.apple.quarantine ~/Downloads/ghostty.saver
   ```

   Adjust the path if you unzipped it somewhere else. Without this, macOS refuses to load the screen saver once you select it, usually saying the file is "damaged". The file is fine. Releases are not signed with an Apple Developer ID, so Gatekeeper refuses the quarantined download.
3. Double-click `ghostty.saver`. System Settings opens and asks whether to install it for you or for all users. Choose one.
4. Select **ghostty** in the list.

Requires macOS 12 or later, Apple Silicon or Intel.

The Screen Saver pane is **System Settings → Screen Saver** on macOS 13 to 15, **System Settings → Wallpaper → Screen Saver** on macOS 26 and later (ghostty is under *Other*), and **System Preferences → Desktop & Screen Saver** on macOS 12. To see it right away, hover over the preview at the top of the pane and click **Preview**.

To update, delete the old copy first (see [Uninstall](#uninstall)), then repeat the steps above with the new zip. Each download needs step 2 again. Your color choice is kept.

If you skipped step 2, macOS refuses the screen saver when you select it, and the installed copy carries the flag too. Run step 2, double-click `ghostty.saver` again, confirm the replacement if asked, and select ghostty again. Without Terminal: right after the message, open **System Settings → Privacy & Security**, scroll to *Security*, click **Open Anyway** if it is offered (it stays for about an hour), and select ghostty again.

## Color schemes

The original look is the default. Three more follow the [Catppuccin](https://catppuccin.com/) palette. Each uses the flavor's base as the background and its blue as the accent. The body fades from peach through pink and mauve to that blue.

<img
  alt="The animation looping in Classic and in Catppuccin Frappé, Macchiato and Mocha."
  src="assets/color-schemes.gif"
  width="800">

| Scheme | Background | Body, top to bottom | Accent |
|---|---|---|---|
| Classic (default) | `#000000` | `#d7d7d7` | `#0000e6` |
| Catppuccin Frappé | `#303446` | `#ef9f76` → `#f4b8e4` → `#ca9ee6` → `#8caaee` | `#8caaee` |
| Catppuccin Macchiato | `#24273a` | `#f5a97f` → `#f5bde6` → `#c6a0f6` → `#8aadf4` | `#8aadf4` |
| Catppuccin Mocha | `#1e1e2e` | `#fab387` → `#f5c2e7` → `#cba6f7` → `#89b4fa` | `#89b4fa` |

To pick one:

1. Open the Screen Saver pane (see [Install](#install)) and select **ghostty**.
2. Click **Options…**.
3. Choose a scheme and click **OK**. The preview updates as you choose.

The choice is saved per user and per Mac.

> On macOS 26, the **Options…** button sometimes does nothing. Quit System Settings, open it again, and click **Options…** once more.

## Uninstall

1. In the Screen Saver pane, pick any other screen saver.
2. In Finder choose **Go → Go to Folder…**, paste `~/Library/Screen Savers`, press Return, and drag `ghostty.saver` to the Trash.
3. Log out or restart. Until then, on macOS 14 to 26 the old copy can stay loaded and keep drawing.

Same thing in Terminal (`killall` does step 3 at once):

```bash
rm -rf ~/Library/Screen\ Savers/ghostty.saver
killall legacyScreenSaver 2>/dev/null
```

For an install under `/Library/Screen Savers/` (all users), use `sudo` and that path. The only other trace is one small preference file with the chosen scheme, inside the `legacyScreenSaver` container. It is harmless to leave.

## FAQ

> **It never starts on its own.**

The saver starts after the delay under **Start Screen Saver**: System Settings → Lock Screen on macOS 13 to 15, or Wallpaper → Screen Saver on macOS 26 and later. On macOS 12 it is **Show screen saver after** in the same pane as the list. If **Turn display off when inactive** under Lock Screen (Energy Saver or Battery on macOS 12) is shorter, the screen goes dark first and the saver never shows, so set the saver delay shorter.

> **A new build does not show up after updating or reinstalling.**

`legacyScreenSaver` caches `.saver` bundles. Run `killall legacyScreenSaver` (or reboot) and open System Settings again.

> **`legacyScreenSaver (Wallpaper)` uses more CPU after every activation.**

On macOS 14 to 26, the system keeps an old copy of the screen saver running after each activation. Fixed in 2.1.1: the newest copy on each screen is the only one drawing, so update if you see this. If it still climbs on 2.1.1 or later, add your macOS version and display count to [issue #6](https://github.com/initor/ghostty-screensaver/issues/6). On older builds, `killall legacyScreenSaver` clears it for a while.

> **Does it work on several displays?**

Yes. Every display animates independently at the same rate. The frames load once per process and are shared.

> **What does it cost in battery and CPU?**

About 9 percent of one CPU core while playing (M4, 1080p display), about half that in Low Power Mode, where the loop plays at half speed.

> **Can I use my own frames or colors?**

Frames: yes, see [FRAMES.md](FRAMES.md) and rebuild. Colors: the schemes are one table in `ghostty/GhosttyColorScheme.m`. A pull request that adds a row is welcome.

Still stuck? [Open a bug report](https://github.com/initor/ghostty-screensaver/issues/new?template=bug_report.yml). The form asks for the few details that make fixes fast.

## Develop

Pure Objective-C and Core Text, universal binary, 30 Hz (15 Hz in Low Power Mode). No Electron, no WebView, no daemons. See [CONTRIBUTING.md](CONTRIBUTING.md) for building, project layout, logs, the rendering checks, and releases.

## Acknowledgements

The 235 ASCII frames in `ghostty/static/animation_frames/` were created by the [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames) contributors and are reused here with attribution under MIT (Copyright (c) 2024 Ghostty). All artistic credit for the animation belongs to the upstream authors. The Catppuccin schemes use the [Catppuccin palette](https://github.com/catppuccin/palette) (Copyright (c) 2021 Catppuccin, MIT). The wrapper (view, frame loader, Options sheet, build pipeline) is original work.

If you are an upstream contributor and prefer different attribution wording, or want the frames removed, please open an issue.

## License

MIT. See [LICENSE](LICENSE). The frame corpus and the palette keep their upstream MIT notices, reproduced there.
