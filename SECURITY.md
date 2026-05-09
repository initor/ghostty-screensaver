# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Use GitHub's [private vulnerability reporting](https://github.com/initor/ghostty-screensaver/security/advisories/new)
instead. That keeps the disclosure private until a fix is ready.

If GitHub's reporting flow is unavailable to you, email the maintainer
listed in the [LICENSE](LICENSE) copyright line via the email shown on
their GitHub profile.

## Scope

This is an unsigned macOS screensaver bundle (`.saver`) that runs inside
Apple's `legacyScreenSaver` sandbox. It reads only its bundled
`frame_NNN.txt` resources, makes no network requests, and writes nothing
outside the sandbox. In-scope reports are anything that:

- Causes the bundle to read or write paths it shouldn't.
- Triggers code execution beyond the rendering of bundled ASCII frames.
- Allows a crafted frame file to escape the sandbox or crash the host.

Out of scope:

- The "damaged and can't be opened" Gatekeeper message — that's expected
  for unsigned releases and documented in the README.
- macOS-side issues with `legacyScreenSaver` itself; please report those
  to Apple.

## Response

I'm a single maintainer with a day job; I aim to acknowledge reports
within 7 days and to ship a fix within 30 days for high-severity issues.
I'll credit reporters in the release notes unless asked otherwise.
