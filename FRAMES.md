# Frame Format Specification

The 235 ASCII art frames under `ghostty/static/animation_frames/` are the
content of this screensaver. This document describes their format so new
frames or new highlight colors can be added without reverse-engineering
the loader.

> **Attribution.** The current 235-frame corpus is derived from
> [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames),
> Copyright (c) 2024 Ghostty, redistributed under MIT. See
> [LICENSE](LICENSE) for the full upstream notice. This document covers
> the file format, not the artwork — new contributions under the same
> format are welcome (see [Contributing](README.md#contributing)).

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
  This is verified — see `.planning/review/bench/B1-bundle-verification.md`.

## Encoding

- UTF-8. The loader reads with `NSUTF8StringEncoding` and skips any file
  that fails to decode (logged to the unified log subsystem
  `com.ghostty.screensaver`).
- The corpus is mostly 7-bit ASCII plus the middle dot character `·`
  (U+00B7).
- Do **not** add a BOM; macOS NSString reads UTF-8 BOM-prefixed files
  fine, but it's needless noise.

## Span tag syntax

Inside a `.txt` file, any text wrapped in:

```html
<span class="b">…</span>
```

is rendered in **blue** (sRGB 0,0,230). Everything else is rendered in
**white** (sRGB 215,215,215).

### Behaviors and edge cases

- **Multi-line spans are allowed.** The parser uses the
  `NSRegularExpressionDotMatchesLineSeparators` flag, so the inner
  content of a span can span newlines.
- **Nested spans are not supported.** The parser uses a non-greedy
  match (`(.*?)`), so an outer span will be consumed and any inner
  span tag literals end up rendered as text. Don't nest.
- **Other class names are not supported.** Only `class="b"` is recognized.
  `<span class="r">red</span>` is currently rendered as ordinary white
  text. To add a new color, see *Adding a new color* below.
- **Malformed spans (no closing tag) are ignored.** The regex requires
  a closing `</span>`; any unmatched opening tag is rendered as literal
  text.
- **Whitespace inside tags must be exact.** The regex matches
  `<span class="b">` literally — extra spaces or different attribute
  ordering will not match.

## Adding a new frame

1. Drop the new file in `ghostty/static/animation_frames/` with a name
   that matches `frame_<digits>.txt`.
2. Confirm the digit width matches the surrounding frames so the sort
   order is preserved.
3. Build. Xcode's synchronized group includes it automatically; no
   project-file edit needed.

## Adding a new color

The loader's regex pattern, the attribute dictionaries, and the colors
all live as file-level statics in `ghostty/GhosttyFrameLoader.m`'s
`+initialize`. Adding a new color (say red, `class="r"`) requires three
edits:

1. Add a static for the color:
   ```objc
   static NSColor *sRedColor;
   ```
   and initialize it in `+initialize`:
   ```objc
   sRedColor = [NSColor colorWithSRGBRed:230.0/255.0 green:0.0 blue:0.0 alpha:1.0];
   ```

2. Add a corresponding attribute dictionary:
   ```objc
   static NSDictionary<NSAttributedStringKey, id> *sAttrsRed;
   …
   sAttrsRed = @{
       NSFontAttributeName: sMonospacedFont,
       NSForegroundColorAttributeName: sRedColor
   };
   ```

3. Update `attributedFrameFromRawHTML:`. The current single-class regex
   needs to either become a multi-alternation pattern
   (`<span class="(b|r)">(.*?)</span>`) or be replaced with a more
   structured parser. Pick the appropriate attribute dictionary based on
   the matched class group.

If new colors are likely to keep arriving, consider lifting the color
table to a `@{class: NSColor}` map and replacing the single-class regex
with one that captures `class` as a group.
