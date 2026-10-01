<p align="center">
  <img src="Sources/SnapAny/Resources/AppIcon.png" width="112" alt="SnapAny app icon" />
</p>

<h1 align="center">SnapAny</h1>
<p align="center">Capture, annotate, and frame screenshots on macOS.</p>

[![macOS packages](https://github.com/thinkany-ai/snapany/actions/workflows/macos.yml/badge.svg?branch=dev)](https://github.com/thinkany-ai/snapany/actions/workflows/macos.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

SnapAny is a native screenshot utility built with Swift and AppKit. It stays in the menu bar while you capture your screen, and appears in the Dock when you open an image editor.

> Early development: builds from `dev` are previews, not stable releases. The interface currently uses Chinese labels in most editing controls.

## Features

- **Capture any region:** drag a selection, click a window, or hover over accessible UI components to select them. Scroll through parent regions; hold Option to select the whole window.
- **Annotate:** rectangle, ellipse, arrow, pen, text, and mosaic, with adjustable sizes and colors. Move, restyle, delete, and undo annotations.
- **Edit images:** keep annotations editable after capture, add desktop wallpaper, gradients, a solid color, or a custom background image.
- **Frame screenshots:** adjust horizontal and vertical padding, corner radius, and shadow with a live preview.
- **Export:** copy to the clipboard, save PNG, or pin an image above other windows. Export at the original pixel resolution.
- **Inspect pixels:** view cursor coordinates and RGB values in the capture magnifier.

## Install a development build

1. Open [macOS packages](https://github.com/thinkany-ai/snapany/actions/workflows/macos.yml) and select a successful run for `dev`.
2. Download the **SnapAny-macos-&lt;commit&gt;** artifact (GitHub sign-in is required).
3. Extract the artifact, open the `.dmg`, and drag **SnapAny.app** to **Applications**. A `.zip` alternative and SHA-256 checksums are included.

Packages are Universal binaries for **Apple Silicon and Intel**, requiring **macOS 14 Sonoma or later**. Artifacts are retained for 30 days. Builds with `unsigned` in the filename have an ad-hoc signature and are **not notarized**; macOS Gatekeeper may block them. Builds without that suffix have passed the configured Developer ID signing and Apple notarization pipeline.

## Permissions

Open **System Settings → Privacy & Security**:

| Permission | Purpose |
| --- | --- |
| Screen Recording / Screen & System Audio Recording | Capture the screen. Required for screenshots. |
| Accessibility | Detect individual controls and panels in other apps. Optional; window selection and manual capture still work without it. |

Choose **启用组件自动吸附…** from the menu bar to open Accessibility settings. Some apps expose only their containing window or panel; custom-drawn content cannot always be detected as separate components. Dynamic desktop wallpapers may require importing a local background image instead.

## Usage

Press **Control + Command + A** to capture. Click the highlighted region or drag to create a selection. Use the toolbar to annotate, copy, save, pin, or open **编辑图片** (Edit Image).

| Action | Shortcut / gesture |
| --- | --- |
| Start capture | `⌃⌘A` |
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

In the image editor, use the lower toolbar to annotate and the sidebar to adjust backgrounds, padding (0–600 px per axis), radius (0–80 px), and shadow. The pointer tool selects and moves annotations; double-click text to edit it. Copying and saving keep the editor open. Closing the last editor hides the Dock icon.

Pinned images can be dragged, closed with a double-click or `Esc`, and copied or saved from their context menu.

## Build from source

Requires macOS 14+, Swift 6+, and Xcode Command Line Tools or Xcode. There are no third-party package dependencies. CI uses the `macos-26` runner.

```bash
git clone git@github.com:thinkany-ai/snapany.git
cd snapany
git checkout dev
./scripts/build-app.sh release
open dist/SnapAny.app
```

For a development executable, use `swift run SnapAny`. For a Universal app, use:

```bash
./scripts/build-app.sh release --universal
```

The bundle identifier is currently `ai.snapany.mac.test`. It is kept stable so local rebuilds can retain their macOS privacy permissions. `SIGN_IDENTITY=-` forces ad-hoc signing; otherwise a local Apple Development identity is used when available.

### Tests

The standalone Swift checks work with Command Line Tools and do not require XCTest:

```bash
./scripts/test-focus.sh
./scripts/test-background.sh
./scripts/test-editor.sh
```

They cover selection geometry, background rendering, Retina annotation coordinates, editing/undo, and image export. Cross-application Accessibility behavior, privacy prompts, Dock behavior, and multi-monitor interaction still need manual validation. See [automatic focus notes](docs/automatic-focus.md).

## Automatic macOS packaging

Every push to **`dev`** runs `.github/workflows/macos.yml`: tests → Universal build → DMG + ZIP + SHA-256 checksums → Actions artifact. Pull requests also build development packages. Maintainers can trigger the workflow manually.

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

Source lives in `Sources/SnapAny`, checks in `Tests/SnapAnyTests`, and build helpers in `scripts`. The current app icon can be regenerated with `scripts/render-icon.swift`; generated iconsets and earlier design drafts are excluded from Git.

## License

[MIT](LICENSE) © 2026 SnapAny contributors.
