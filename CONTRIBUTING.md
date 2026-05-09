# Contributing

Thanks for your interest. This is an unofficial fan project — see
[README.md](README.md#ghostty-screensaver) for the relationship to the
upstream [Ghostty](https://ghostty.org/) terminal.

## Filing issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml) so the
environment-specific bits (macOS version, chip, Low Power Mode state) are
captured up front. For installation friction, check the README's
[Install](README.md#install) section first — most reports collapse to either
the quarantine flag or the `legacyScreenSaver` cache.

## Running locally

```bash
git clone https://github.com/initor/ghostty-screensaver.git
cd ghostty-screensaver
open ghostty.xcodeproj   # Xcode 16.2+
# Cmd-R runs the saver in Xcode's preview pane.
```

For an end-to-end test against the real `legacyScreenSaver` host, do a
Release build, copy `ghostty.saver` into `~/Library/Screen Savers/`, and
`killall legacyScreenSaver`. Logs:

```bash
log stream --predicate 'subsystem == "com.initor.ghostty-screensaver"'
```

`os_signpost` intervals (`FrameLoad`, `DrawFrame`, `Tick`) appear in
**Instruments → Points of Interest** with no extra build flags.

## Pull requests

- Keep changes focused — one concern per PR. CI runs on every PR
  (`.github/workflows/build.yml`).
- Match the existing style: pure Objective-C, ARC, file-level statics for
  hot-path constants, attribute dictionaries shared across instances.
- Document non-obvious choices in code comments. Don't explain *what* —
  explain *why*.

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
bot — this note is the contract.

## Format reference

See [FRAMES.md](FRAMES.md) for filename rules, encoding, the
`<span class="b">…</span>` highlight tag, and how to wire a third color.
