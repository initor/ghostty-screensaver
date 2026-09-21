# Frame Format Specification

The 235 ASCII art frames under `ghostty/static/animation_frames/` are the
content of this screensaver. This document describes their format so new frames or new color schemes can be added without reverse-engineering
the loader.

> **Attribution.** The current 235-frame corpus is derived from
> [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames),
> Copyright (c) 2024 Ghostty, redistributed under MIT. See
> [LICENSE](LICENSE) for the full upstream notice. This document covers
> the file format, not the artwork. New contributions under the same
> format are welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## File location and naming

- **Path:** `ghostty/static/animation_frames/frame_NNN.txt`
- **Naming pattern:** `frame_<digits>.txt` (validated by the loader against
  the regex `^frame_[0-9]+\.txt$`). Filenames that do not match are
  silently ignored at load time.
- **Sort order:** plain lexicographic `compare:`. Filenames must be
  zero-padded to a fixed width (current corpus uses three digits:
  `frame_001.txt` through `frame_235.txt`) so lexicographic order matches
  numeric order. If you add `frame_236.txt`, you do **not** need to widen
  the padding; if you reach `frame_1000.txt`, you do.
- **Bundle layout:** Xcode's synchronized root group (`PBXFileSystemSynchronizedRootGroup`)
  flattens the on-disk structure when copying resources, so every frame
  ends up at `Contents/Resources/frame_NNN.txt` in the built `.saver`.
  `tests/render_bundle.m` checks the resource count and order in CI and before every release.

## Encoding

- UTF-8. The loader reads with `NSUTF8StringEncoding` and skips any file
  that fails to decode (logged to the unified log subsystem
  `com.initor.ghostty-screensaver`).
- The corpus is mostly 7-bit ASCII plus the middle dot character `·`
  (U+00B7).
- Do **not** add a BOM; macOS NSString reads UTF-8 BOM-prefixed files
  fine, but it is needless noise.

## Span tag syntax

Inside a `.txt` file, any text wrapped in:

```html
<span class="b">…</span>
```

is rendered in the color scheme's **accent** color. Everything else is
rendered in the scheme's **body** color. In the default Classic scheme the
accent is blue (sRGB 0,0,230) and the body is light gray (sRGB 215,215,215).
See *Color roles and schemes* below.

### Behaviors and edge cases

- **Multi-line spans are allowed.** The parser uses the
  `NSRegularExpressionDotMatchesLineSeparators` flag, so the inner
  content of a span can span newlines.
- **Nested spans are not supported.** The parser uses a non-greedy
  match (`(.*?)`), so an outer span will be consumed and any inner
  span tag literals end up rendered as text. Do not nest.
- **Other class names are not supported.** Only `class="b"` is recognized.
  `<span class="r">red</span>` is rendered as ordinary body text. The
  corpus has exactly one accent role (17,858 spans, all `class="b"`).
- **Malformed spans (no closing tag) are ignored.** The regex requires
  a closing `</span>`; any unmatched opening tag is rendered as literal
  text.
- **Whitespace inside tags must be exact.** The regex matches
  `<span class="b">` literally. Extra spaces or a different attribute
  order will not match.

## Adding a new frame

1. Drop the new file in `ghostty/static/animation_frames/` with a name
   that matches `frame_<digits>.txt`.
2. Confirm the digit width matches the surrounding frames so the sort
   order is preserved.
3. Build. Xcode's synchronized group includes it automatically; no
   project-file edit needed.

## Color roles and schemes

A frame has two color roles: **body** (all plain text) and **accent** (the
text inside `<span class="b">`). A color scheme adds a **background** and
assigns one sRGB color to each role. The body may instead be a vertical
gradient, one color per row interpolated between four stops. The loader
bakes the text colors into the attributed strings at load time as `CGColor`
values under `kCTForegroundColorAttributeName`, one run per row for a
gradient; the view sets the background on its layer.

The schemes are one static table in `ghostty/GhosttyColorScheme.m`:

```objc
{ "catppuccin-mocha", "Catppuccin Mocha", 0x1e1e2e, 0xcdd6f4, 0x89b4fa, { 0xfab387, 0xf5c2e7, 0xcba6f7, 0x89b4fa } },
//  identifier         display name       background body      accent    gradient stops, top to bottom (all zero = flat)
```

The identifier is stored in `ScreenSaverDefaults` and must never change once
shipped. To add a scheme, add a row here and the same row to the table in
`tests/render_bundle.m`, then run `tests/verify-rendering.sh`. The harness
asserts the popup order, the display names, and the exact pixel colors.

Adding a second accent role (a new span class) would need a second regex
group and one more accent color per scheme. Nothing in the corpus uses one
today.
