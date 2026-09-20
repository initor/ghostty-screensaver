# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- The README color scheme GIF kept only one palette for all four tiles, so
  the three dark Catppuccin flavors looked alike. It is now remapped to an
  explicit palette of each scheme's own colors.

## [1.8.1] — 2026-09-20

### Added
- Color schemes. Pick one under System Settings → Screen Saver → ghostty →
  Options…: Classic (the original look, still the default), Catppuccin Latte,
  Frappé, Macchiato, and Mocha. The choice is stored per user and per Mac with
  `ScreenSaverDefaults` under the key `ColorScheme`.
- Per scheme rendering checks and an Options sheet smoke test in
  `tests/render_bundle.m`.
- `assets/color-schemes.gif`, the loop in the four Catppuccin schemes.

### Changed
- The System Settings preview scales the animation to fit instead of cropping
  it. Displays that fit the full canvas are unchanged.
- README rewritten around install and color schemes. Developer content moved
  to CONTRIBUTING.md. FRAMES.md describes the color roles.

### Fixed
- FRAMES.md named the old log subsystem and linked a file outside the repo.

### Removed
- `assets/demo_light.png`, unreferenced since 1.7.4.

Existing installs keep the original colors. No migration.

## [1.8.0] — 2026-09-20

### Changed
- Text colors are stored as Core Graphics colors under the Core Text
  attribute key, so no color conversion happens per tick.
- Frame size and origin are computed once per bounds instead of once per
  tick. Together with the color change, draw time per frame drops by about
  a third (1.89 to 1.18 ms at 1080p on an M4).
- The whole cycle ink measurement runs once per process instead of once per
  view, which removes a 74 ms stall on every additional display and on the
  Settings preview.
- Low Power Mode changes apply on the main thread.
- The release job runs the rendering checks from the release commit instead
  of from `main`.

### Fixed
- A failed or empty first frame load is no longer cached for the life of
  the process.
- README no longer claims `drawRect:` is allocation free, or that the frame
  rate depends on AC power.

## [1.7.5] — 2026-09-16

### Fixed
- One vertical anchor for the whole animation loop, measured from the union
  of visible ink, so the ghost no longer recenters per frame (PR #22).

## [1.7.4] — 2026-09-16

### Changed
- README shows the original animated GIF in both GitHub themes (PR #21). No
  GitHub release was published for this tag. See 1.7.5.

## [1.7.3] — 2026-09-15

### Fixed
- Vertical centering measured from visible glyphs instead of the text frame
  (PR #20).

## [1.7.2] — 2026-09-15

### Fixed
- The release script finds draft releases through the authenticated listing
  (PR #19).

## [1.7.1] — 2026-09-15

### Fixed
- Publish the previously merged horizontal-centering correction missing from v1.7.0.
- Recompute centering when the host changes view bounds without advancing the animation.

### Added
- Native rendering regression checks and downloadable CI candidate artifacts.
- Automatic patch releases after successful CI on `main`, pinned to the tested commit with duplicate-release protection.
- `LICENSE` file at repo root with wrapper MIT (Wayne Wen, 2026) and upstream
  MIT (Ghostty, 2024) reproduced per MIT clause 2.
- `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`,
  `.github/dependabot.yml`.
- `## Compatibility` table in README covering Apple Silicon × Intel across
  macOS 12–26.
- `## FAQ` section with the six most-anticipated user questions.

### Changed
- README rewritten end-to-end. New structure: title + unofficial-fan-project
  callout / badges / hero GIF / Install / Compatibility / How it works /
  FAQ / Develop / Contributing / Acknowledgements / License.
- Log subsystem renamed from `com.ghostty.screensaver` to
  `com.initor.ghostty-screensaver` to match `PRODUCT_BUNDLE_IDENTIFIER`.
- Centering math in `GhosttyView.drawRect:` now measures a canonical
  100-space line via `CTLineGetTypographicBounds` instead of relying on
  `CTFramesetterSuggestFrameSizeWithConstraints`, which silently strips
  trailing whitespace and pushed the visible glyphs ~77 pt right of midX.
- Expanded `.gitignore` with standard Xcode/macOS entries plus `.planning/`.

## [1.7.0] — 2026-05-05

### Fixed
- CI: force universal build via `-destination 'generic/platform=macOS'` and
  `ONLY_ACTIVE_ARCH=NO`. Plain `xcodebuild build` was locking to the
  runner's host arch (arm64) on Xcode 26.

### Changed
- `ghosttyView` renamed to `GhosttyView` (proper Cocoa naming).
- View throttles to 15 FPS in Low Power Mode via
  `NSProcessInfoPowerStateDidChangeNotification`.

### Removed
- B5 XCTest harness. (This entry once also listed the B6 `os_signpost`
  tracks. They stayed in and are still on.)

### Added
- Real Development section in README; `FRAMES.md` spec.

## [1.6.5] — 2026-02-09

### Fixed
- Use `CGContext` transform instead of `isFlipped` for upside-down animation.

## [1.6.0] — 2026-02-09

### Fixed
- Ad-hoc sign unsigned builds.
- Memory leak in screensaver hot path.

## [1.5.0] — earlier

CI: conditional signing in release workflow.

## [1.4.0] and earlier

See git history: `git log v1.4.0`.

[Unreleased]: https://github.com/initor/ghostty-screensaver/compare/v1.8.1...HEAD
[1.8.1]: https://github.com/initor/ghostty-screensaver/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/initor/ghostty-screensaver/compare/v1.7.5...v1.8.0
[1.7.5]: https://github.com/initor/ghostty-screensaver/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/initor/ghostty-screensaver/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/initor/ghostty-screensaver/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/initor/ghostty-screensaver/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/initor/ghostty-screensaver/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.7.0
[1.6.5]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.6.5
[1.6.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.6.0
[1.5.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.5.0
