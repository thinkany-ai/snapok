<p align="center">
  <img src="Sources/Snapok/Resources/AppIcon.png" width="112" alt="Snapok app icon" />
</p>

<h1 align="center">Snapok</h1>
<p align="center">Capture, annotate, and frame screenshots on macOS.</p>
<p align="center"><a href="https://snapok.app">snapok.app</a> · <a href="https://github.com/thinkany-ai/snapok/issues">Report an issue</a></p>

[![macOS packages](https://github.com/thinkany-ai/snapok/actions/workflows/macos.yml/badge.svg?branch=dev)](https://github.com/thinkany-ai/snapok/actions/workflows/macos.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

Snapok is a native screenshot utility built with Swift and AppKit. It lives in the Dock and the menu bar: the global hotkey works anywhere, and the main window is a library of your past screenshots.

> Early development: builds from `dev` are previews, not stable releases. English is the default language; Simplified Chinese is available in Settings → General → Language (restart to apply).

## Features

- **Capture any region:** drag a selection, click a window, or hover over accessible UI components to select them. Detect the Dock, menu bar, and status items as well. Scroll through parent regions; hold Option to select the whole window or system UI container.
- **Annotate:** rectangle, ellipse, arrow, pen, text, and mosaic, with adjustable sizes and colors. Move, restyle, delete, and undo annotations.
- **Edit images:** keep annotations editable after capture, add desktop wallpaper, gradients, a solid color, or a custom background image.
- **Frame screenshots:** adjust horizontal and vertical padding, corner radius, and shadow with a live preview.
- **Export:** copy to the clipboard, save PNG, or pin an image above other windows. Export at the original pixel resolution.
- **Inspect pixels:** view cursor coordinates and RGB values in the capture magnifier.
- **Screenshot library:** every finished capture is saved with its annotations, grouped by day and searchable by title, tag, or the text inside the image. Open any screenshot to keep editing it.
- **AI tools:** recognize text and mask phone numbers, emails, ID numbers, and keys on-device; translate a screenshot or ask a question about it with Claude; optionally name and tag new screenshots automatically.

## Install a development build

1. Open [macOS packages](https://github.com/thinkany-ai/snapok/actions/workflows/macos.yml) and select a successful run for `dev`.
2. Download the **Snapok-macos-&lt;commit&gt;** artifact (GitHub sign-in is required).
3. Extract the artifact, open the `.dmg`, and drag **Snapok Dev.app** to **Applications**. A `.zip` alternative and SHA-256 checksums are included.

Packages are Universal binaries for **Apple Silicon and Intel**, requiring **macOS 14 Sonoma or later**. Artifacts are retained for 30 days. Builds with `unsigned` in the filename have an ad-hoc signature and are **not notarized**; macOS Gatekeeper may block them. Builds without that suffix have passed the configured Developer ID signing and Apple notarization pipeline.

## Permissions

Open **System Settings → Privacy & Security**:

| Permission | Purpose |
| --- | --- |
| Screen Recording / Screen & System Audio Recording | Capture the screen. Required for screenshots. |
| Accessibility | Detect individual controls and panels in other apps. Also used to locate the visible Dock on newer macOS versions. Optional; ordinary window selection and manual capture still work without it. |

Choose **Enable Component Snapping…** from the menu bar to open Accessibility settings. Some apps expose only their containing window or panel; custom-drawn content cannot always be detected as separate components. Dynamic desktop wallpapers may require importing a local background image instead.

## Usage

Press **Control + Command + A** to capture (**Shift + Option + A** in Snapok Dev). Click the highlighted region or drag to create a selection. Use the toolbar to annotate, copy, save, pin, or open **Edit Image**.

| Action | Shortcut / gesture |
| --- | --- |
| Start capture | `⌃⌘A` (Snapok Dev: `⇧⌥A`) |
| Select full window | Hold `⌥` while hovering |
| Expand / shrink automatic selection | Scroll up / down |
| Move / resize selection | Drag inside / drag edges or handles |
| Nudge selection | Arrow keys; `Shift` for 10-point steps |
| Edit image | `⌘B` after selecting a capture |
| Copy capture | `Enter`, `⌘C`, or double-click the selection |
| Save PNG | `⌘S` |
| Undo annotation edit | `⌘Z` |
| Delete selected annotation | `Delete` |
| Reselect / cancel capture | Right-click / `Esc` |
| Close image editor | `⌘W` |

In the image editor, use the lower toolbar to annotate and the sidebar to adjust backgrounds, padding (0–600 px per axis), radius (0–80 px), and shadow. The pointer tool selects and moves annotations; double-click text to edit it. Copying and saving keep the editor open. The **AI Tools** menu in the editor header recognizes text, masks sensitive information (undoable), translates, and answers questions about the screenshot.

Pinned images can be dragged, closed with a double-click or `Esc`, and copied or saved from their context menu.

### Screenshot library

Click the Dock icon, or choose **Open Library** from the menu bar, to open the main window. Its sidebar switches between **Library**, **General**, and **AI Settings**, and has a **Take Screenshot** button. Closing the window keeps Snapok running so the hotkey still works.

- Copying, saving, pinning, or editing a capture adds it to the library; cancelled captures are not saved.
- Double-click a screenshot (or press `Enter`) to edit it; annotations are written back when the editor closes.
- Right-click for copy, pin, copy recognized text, rename, reveal in Finder, and delete (`Delete` also works).
- Search covers titles, tags, and text recognized on-device after each capture.
- Files live in `~/Library/Application Support/Snapok/History` (`Snapok Dev/History` for development builds), one folder per screenshot (`original.png`, `thumbnail.png`, `meta.json`). Screenshots older than the retention period (default 30 days) are deleted automatically.

### Settings and AI

Open **Settings…** (`⌘,`) or pick a settings page in the sidebar. **General** controls auto-save, retention (7/30/90 days or forever), and clearing the library. **AI Settings** takes an Anthropic API key (stored in the Keychain), the model (default `claude-opus-5-5`), the API base URL, and the translation language.

| Feature | Runs | Needs API key |
| --- | --- | --- |
| Recognize text, search by text | On-device (Vision) | No |
| Mask sensitive information | On-device (Vision + pattern matching) | No |
| Translate, ask about a screenshot | Claude API | Yes |
| Auto title and tags (off by default) | Claude API | Yes |

AI features send the screenshot with its current annotations, so anything already masked stays masked. Automatic naming sends every new screenshot to the API, so it stays off until you enable it.

## Build from source

Requires macOS 14+, Swift 6+, and Xcode Command Line Tools or Xcode. There are no third-party package dependencies. CI uses the `macos-26` runner.

```bash
git clone git@github.com:thinkany-ai/snapok.git
cd snapok
git checkout dev
./scripts/build-app.sh release
open "dist/Snapok Dev.app"
```

For a development executable, use `swift run Snapok`. For a Universal app, use:

```bash
./scripts/build-app.sh release --universal
```

### Development and release channels

Local builds default to the development channel; set `CHANNEL=release` for the release app. The two install side by side and never share data:

| | Development (default) | Release |
| --- | --- | --- |
| Build | `./scripts/build-app.sh release` | `CHANNEL=release ./scripts/build-app.sh release` |
| App | `dist/Snapok Dev.app`, DEV badge on the icon | `dist/Snapok.app` |
| Bundle identifier | `ai.snapok.mac.dev` | `ai.snapok.mac` |
| Screenshot library | `~/Library/Application Support/Snapok Dev/` | `~/Library/Application Support/Snapok/` |
| Settings / Keychain service | `ai.snapok.mac.dev` | `ai.snapok.mac` |
| Log | `~/Library/Logs/Snapok Dev.log` | `~/Library/Logs/Snapok.log` |
| Capture hotkey | `⇧⌥A` | `⌃⌘A` |

The channel is stored as `SnapokChannel` in Info.plist; `swift run` counts as development. Each channel needs its own Screen Recording (and, for component focus, Accessibility) permission. On first launch, the development build moves the library, settings, and API key from pre-rename SnapAny builds into its own storage; the release build starts empty.

CI builds the development channel for `dev` pushes and pull requests, and the release channel for `v*` tags or a manual run with `channel: release`.

Bundle identifiers stay stable across rebuilds so macOS keeps privacy permissions. `SIGN_IDENTITY=-` forces ad-hoc signing; otherwise a local Apple Development identity is used when available.

### Tests

The standalone Swift checks work with Command Line Tools and do not require XCTest:

```bash
./scripts/test-localization.sh
./scripts/test-focus.sh
./scripts/test-background.sh
./scripts/test-editor.sh
./scripts/test-history.sh
```

They cover language defaults and persistence, selection geometry (including system UI), background rendering, Retina annotation coordinates, editing/undo, image export, history storage (in a temporary folder), sensitive-value detection, and on-device text recognition. Cross-application Accessibility behavior, privacy prompts, Dock behavior, and multi-monitor interaction still need manual validation. See [automatic focus notes](docs/automatic-focus.md).

## Automatic macOS packaging

Every push to **`dev`** builds **Snapok Dev** through `.github/workflows/macos.yml`: tests → Universal build → DMG + ZIP + SHA-256 checksums → Actions artifact. Pull requests also build development packages. Version tags (`v*`) build the release channel, **Snapok**. Maintainers can also select either channel when triggering the workflow manually.

The packaging follows the Spotcat project: `lipo` combines both architectures, `ditto` creates ZIPs, and `hdiutil` creates a DMG with an Applications shortcut. If all signing secrets are configured, it also signs with hardened runtime, notarizes and staples the app and DMG, and verifies them with Gatekeeper.

| GitHub Actions secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12`, including the private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application identity name |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_PASSWORD` | Apple app-specific password |
| `APPLE_TEAM_ID` | Apple Developer team ID |

Configure them on **this repository** under Settings → Secrets and variables → Actions. Secrets cannot be read back or automatically copied from another repository. The setup helper uses the same variable names as Spotcat:

```bash
# Set the four APPLE_* identity/notarization variables in your local environment first.
# The helper prompts for the certificate password, or reads APPLE_CERTIFICATE_PASSWORD.
./scripts/setup-release-secrets.sh /path/to/DeveloperID.p12
```

Do not commit certificates, private keys, passwords, or `.env` files. Without a certificate, CI still produces clearly labeled unsigned development packages; an incomplete signing configuration fails rather than claiming a signed release.

Local packaging:

```bash
./scripts/package-macos.sh --unsigned
# Requires Developer ID in the keychain and the four APPLE_* variables:
./scripts/package-macos.sh --signed
```

Outputs are in `dist/archives/`. `PACKAGE_SUFFIX` controls the filename suffix and `BUILD_NUMBER` overrides the bundled build number. The workflow uploads artifacts; it does not create a GitHub Release or publish to a CDN.

## Contributing

Issues and pull requests are welcome. Branch from `dev`, keep changes focused, describe how to reproduce a bug, and run the relevant checks before submitting. For UI changes, include before/after screenshots and test at the minimum window size. Never include private screenshots or signing credentials in reports.

Source lives in `Sources/Snapok`, checks in `Tests/SnapokTests`, and build helpers in `scripts`. The current app icon can be regenerated with `scripts/render-icon.swift`; generated iconsets and earlier design drafts are excluded from Git.

## Language

Snapok starts in English by default. Choose **Settings → General → Language → 简体中文** to use Simplified Chinese. The choice is saved and applies after restarting Snapok, including menus, the library, capture tools, and the image editor. AI answers and newly generated titles follow the app language; existing titles and the separate translation target are preserved.

## License

Snapok is licensed under [AGPL-3.0](LICENSE) © 2026 ThinkAny, LLC. A commercial license without
the AGPL's copyleft obligations is available — contact support@thinkany.ai.
