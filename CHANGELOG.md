# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
- B5 XCTest harness and B6 `os_signpost` Points-of-Interest tracks.

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

[Unreleased]: https://github.com/initor/ghostty-screensaver/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.7.0
[1.6.5]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.6.5
[1.6.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.6.0
[1.5.0]: https://github.com/initor/ghostty-screensaver/releases/tag/v1.5.0
