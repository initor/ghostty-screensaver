# Ghostty Screensaver

A macOS screensaver that animates ASCII frames, originally inspired by [ghostty.org](https://ghostty.org/).

![Ghostty Screensaver Demo](assets/demo_1440.gif)

## Installation

### Option A: Download from Releases

1. Go to the [Releases](https://github.com/initor/ghostty-screensaver/releases) of this repository and download the latest `.zip` file.
2. Unzip the file to extract the `.saver`.
3. Double-click the `.saver` file and follow any prompts to install.
   - Alternatively, manually move it to `~/Library/Screen Savers/`.

### Option B: Build from Source

1. Clone or download this repository.
2. Open the Xcode project.
3. Build the `.saver` target.
4. Find the `.saver` file in your `~/Library/Developer/Xcode/DerivedData/…/Build/Products/Debug/` (or “Products” in Xcode).
5. Double-click the `.saver` file and follow any prompts to install.
   - Copy or drag the `.saver` file into `System Settings → Screen Saver` or into `~/Library/Screen Savers/`.
6. Select `Ghostty Screensaver` in your Screen Saver preferences.

### Installation Issues & Troubleshooting

> “App cannot be opened because the developer cannot be verified”

Because Ghostty Screensaver is not distributed via the Mac App Store, macOS may block the `.saver` file when you try to install. To work around this:

1. System Settings (macOS Ventura or later):

- Open `System Settings → Privacy & Security`.
- Scroll down to the “Security” section. You should see a warning about “Ghostty.saver” being blocked.
- Click `“Open Anyway”` to allow installation.

2. Security & Privacy (macOS Monterey or earlier):

- Go to System Preferences → Security & Privacy → General.
- You might see a message that says “Ghostty.saver was blocked from opening because it is not from an identified developer.”
- Click “Open Anyway” and confirm.

3. Using [Ghostty](https://ghostty.org/) 👻: If you still can’t install or macOS complains about quarantine:

- Navigate to the folder where you placed `ghostty.saver`.
- Run the following command:
```bash
sudo xattr -d com.apple.quarantine ghostty.saver
```
- Double-click the `.saver` file again to install.

> [!NOTE]
> Once installed, if the new version of the screensaver doesn’t **load** immediately, try:

- Rebooting your Mac, or
- Killing the `legacyScreenSaver` processes in Activity Monitor (search for “legacyScreenSaver” and force quit).

macOS should then pick up the newly installed `.saver` file.

## Development

### Features

- Loads ASCII frames from `.txt` files in the screensaver’s Resources folder.
- Parses `<span class="b">...</span>` as blue `(0,0,230)`, everything else is white `(215,215,215)`.
- Animates frames at 30 FPS.
- Basic fallback if no frames are found.

### Project Structure

`ghosttyView.h/.m` – The main ScreenSaverView subclass that:
- Loads `.txt ` frames (concurrently if desired).
- Parses `<span class="b">` for color coding.
- Draws each frame in `drawRect:`.
- Animates them via `animateOneFrame`.

## Credits

Original ASCII frames from [ghostty.org](https://ghostty.org/) via the [ghostty-org/website](https://github.com/ghostty-org/website/tree/main/terminals/home/animation_frames) repository.
