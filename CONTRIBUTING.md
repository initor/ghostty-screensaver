# Contributing

Thanks for your interest. This is an unofficial fan project. See
[README.md](README.md#ghostty-screensaver) for the relationship to the
upstream [Ghostty](https://ghostty.org/) terminal.

## Filing issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml) so the
environment (macOS version, chip, Low Power Mode, color scheme) is captured
up front. For install friction, check the README's
[Install](README.md#install) section first. Most reports come down to the
quarantine flag or the `legacyScreenSaver` cache.

## Building

```bash
git clone https://github.com/initor/ghostty-screensaver.git
cd ghostty-screensaver
open ghostty.xcodeproj   # Xcode 16.2 or later
```

<kbd>⌘ B</kbd> builds `ghostty.saver`. A `.saver` has no host executable to
run from Xcode. To try it in the real host, copy the bundle into
`~/Library/Screen Savers/`, run `killall legacyScreenSaver`, and open
**System Settings → Screen Saver**.

CI and the release job run the rendering checks against a built bundle:

```bash
bash tests/verify-rendering.sh /path/to/ghostty.saver ./build/verification
```

They load the bundle, draw every frame of the loop at several sizes, compare
the pixels against an independent Core Text reference, and check each color
scheme and the Options sheet. About 50 s. Evidence lands in the output
directory as `results.json` plus sample PNGs.

## How it works

`GhosttyView` is a `ScreenSaverView` subclass loaded by macOS's
`legacyScreenSaver` host. At init it reads the chosen color scheme from
`ScreenSaverDefaults`, asks `GhosttyFrameLoader` for the 235 frames colored
for that scheme, and sets the layer background. Each tick it builds a
`CTFramesetter` and `CTFrame` for the current frame, draws it, and releases
both. Nothing is retained between ticks: `NSLayoutManager` caches grew
without bound under per frame swaps, and retaining Core Text frames would
cost 45 MB for 0.1 ms per tick.

- Frames are loaded once per process for the active scheme and shared
  across displays and the System Settings preview. The loader keeps the
  last scheme only. Changing schemes reloads.
- The canvas size and the vertical anchor are measured once per process.
  The anchor is the midpoint of the visible ink over the whole loop, so the
  ghost does not jump when a frame's outline changes.
- Placement is computed once per bounds. When the bounds are smaller than
  the 963 by 779 pt canvas (the Settings preview), the drawing is scaled to
  fit inside an 8 percent margin. Displays that fit the canvas are unchanged.
- 30 Hz, 15 Hz in Low Power Mode via `NSProcessInfoPowerStateDidChangeNotification`.
  On macOS 14 and later a `CADisplayLink` paces the ticks to the display's
  refresh (every other refresh at 60 Hz), created in `startAnimation` and
  invalidated in `stopAnimation`. The host timer is pushed out to once an
  hour. Before 14 the host's timer runs as is.
- On macOS 14 to 26 the host process stays resident, starts a new view per
  activation and never stops the old one. A full-screen view that starts,
  or lands in a window, retires the older full-screen view on the same
  screen: hidden, timer and display link stopped, no drawing. A restarted
  view takes over again. Preview-sized, detached and off-screen views are
  left alone. `tests/render_bundle.m` drives this with windows that are
  never shown.
- `os_signpost` Points of Interest (`FrameLoad`, `DrawFrame`, `Tick`) are
  always on. Instruments picks them up with no build flags.

## Color schemes

The scheme table lives in `ghostty/GhosttyColorScheme.m`. Each row is an
identifier, a display name, three sRGB colors (background, body glyphs, and
the accent glyphs inside `<span class="b">`), and four gradient stops. With
stops, the body is drawn one color per row, top to bottom, interpolated
between the stops. The formula is in `GhosttyColorScheme.h` and the harness
recomputes it. All zero stops mean a flat body. The identifier is what
`ScreenSaverDefaults` stores under the key `ColorScheme` for the module
`com.initor.ghostty-screensaver`, so it must never change once shipped. A
missing or unknown value resolves to `classic`.

To add a scheme:

1. Add a row to the table in `ghostty/GhosttyColorScheme.m`.
2. Add the same row to the table at the top of `tests/render_bundle.m`. The
   harness asserts popup order, display names, and exact pixel colors
   against it.
3. Run the rendering checks.
4. Add the row to the README table and regenerate `assets/color-schemes.gif`:
   render every frame of each scheme through `drawRect:` at 1040 by 820
   (the ghost fits with no crop), tile them 2 by 2 at 600 px per scheme,
   scale to 800 px, and encode every other frame at 15 fps with one
   128 color palette taken from a representative frame, no dithering. A
   palette chosen per frame breaks frame to frame optimization and the
   file balloons. That keeps the file near 3.4 MB.

Never write `ScreenSaverDefaults` from a test. Outside the sandbox the write
lands in your own `~/Library/Preferences/ByHost`. The harness applies schemes
through `-[GhosttyView applyScheme:]`, the same path the Options sheet uses.

## Project layout

```
ghostty/
├── GhosttyView.{h,m}            ScreenSaverView subclass: lifecycle, drawing, LPM, sheet hooks
├── GhosttyFrameLoader.{h,m}     Bundle scan, span parser, per scheme frames, geometry
├── GhosttyColorScheme.{h,m}     Scheme table, lookup, preference read and write
├── GhosttyOptionsSheet.{h,m}    The Options window, built in code (no XIB)
└── static/animation_frames/     235 frame_NNN.txt files (the content)
ghostty.xcodeproj/               PBXFileSystemSynchronizedRootGroup: new files under ghostty/ join the target
.github/workflows/               CI: universal build and rendering checks; automatic releases
tests/                           Rendering checks against a built saver
FRAMES.md                        Frame file format
LICENSE                          MIT (wrapper), upstream MIT (frames), MIT (Catppuccin palette)
```

Pure Objective-C, ARC, deployment target macOS 12. Rendering uses Core Text.

## Logs

```bash
log stream --predicate 'subsystem == "com.initor.ghostty-screensaver"' --info
```

The resolved scheme is logged at default level on every view creation, so it
also shows in `log show`. Loader timings and view init are info level and
need `log stream`. Per draw timing exists only as the `DrawFrame` signpost.
Read it in Instruments or with `log stream --signpost`.

## Releasing

Every push to `main` that changes code and passes CI publishes the next
patch release automatically, pinned to the commit CI checked. Pushes that
change only documentation, assets, issue templates or workflows skip CI and
never release, so a manual tag must point at a commit that changes code.
PR builds and failed runs never publish. Rerunning CI for a released commit
does not create another version.

For a minor or major version, the tag has to reach `origin` together with the
merge commit, or the automation allocates a patch tag first:

```bash
git checkout main
git merge --no-ff my-feature-branch
git tag v1.8.0
git push --atomic origin main v1.8.0
```

Expect one failed Release run from the tag push (CI has not run yet). The
run triggered by CI then publishes the tag once. The release job runs the
rendering checks from the release commit, so a harness change ships with the
code it gates.

The workflow signs and notarizes when `DEVELOPER_ID_*` and `APPLE_*` secrets
exist. Otherwise it ad hoc signs and adds quarantine instructions to the
release notes.

## Pull requests

- Keep changes focused. One concern per PR. CI runs on every PR
  (`.github/workflows/build.yml`).
- Match the existing style: pure Objective-C, ARC, file level statics for
  shared state, comments that explain why rather than what.
- If a change touches drawing, run the rendering checks before opening the PR.

## Inbound license

By submitting code:

- You license your contribution under MIT (inbound = outbound).
- You affirm the contribution is yours to license, or comes from a source
  whose terms permit redistribution under MIT (cite the source in the PR).

By submitting a frame file (`ghostty/static/animation_frames/frame_NNN.txt`):

- You affirm you authored it, **or** it is sourced from a repo whose license
  permits redistribution under this project's terms (cite the source and the
  upstream license in the PR).
- You grant downstream users the same redistribution rights as the existing
  `ghostty-org/website` corpus (MIT, Copyright (c) 2024 Ghostty).

PRs that cannot establish provenance for new frames will be closed. No CLA
bot. This note is the contract.

## Format reference

See [FRAMES.md](FRAMES.md) for filename rules, encoding, and the
`<span class="b">…</span>` accent tag.
