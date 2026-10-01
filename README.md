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

> Early development: builds from `dev` are previews, not stable releases. English is the default language; Simplified Chinese is available in Settings → General → Language (applies immediately).

## Features

- **Capture any region:** drag a selection, click a window, or hover over accessible UI components to select them. Detect the Dock, menu bar, and status items as well. Scroll through parent regions; hold Option to select the whole window or system UI container.
- **Annotate:** rectangle, ellipse, arrow, pen, text, and mosaic, with adjustable sizes and colors. Move, restyle, delete, and undo annotations.
- **Edit images:** keep annotations editable after capture, add desktop wallpaper, gradients, a solid color, or a custom background image.
- **Frame screenshots:** adjust horizontal and vertical padding, corner radius, and shadow with a live preview.
- **Export:** copy to the clipboard, save PNG, or pin an image above other windows. Export at the original pixel resolution.
- **Inspect pixels:** view cursor coordinates and RGB values in the capture magnifier.
- **Screenshot library:** every finished capture is saved with its annotations, grouped by day and searchable by title, tag, or the text inside the image. Open any screenshot to keep editing it.
- **AI tools:** recognize text and mask phone numbers, emails, ID numbers, and keys on-device; translate a screenshot or ask a question about it with the model of your choice (Anthropic or any OpenAI-compatible provider, with your own key); optionally name and tag new screenshots automatically.

## Install a development build

Download the latest signed development build from **https://cdn.snapok.app/dev/Snapok-Dev.dmg**, open it, and drag **Snapok Dev.app** to **Applications**. It updates itself from then on (see [Updates](#updates)).

Builds of other commits, and pull request builds, are attached to their workflow runs:

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
| Start capture | `⌃⌘A` (Snapok Dev: `⌥⇧A`); change it in Settings → General |
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

Click the Dock icon, or choose **Open Library** from the menu bar, to open the main window. Its sidebar switches between **Library**, **General**, **Models**, and **About**, and has a **Take Screenshot** button. Closing the window keeps Snapok running so the hotkey still works.

- Copying, saving, pinning, or editing a capture adds it to the library; cancelled captures are not saved.
- Double-click a screenshot (or press `Enter`) to edit it; annotations are written back when the editor closes.
- Right-click for copy, pin, copy recognized text, rename, reveal in Finder, and delete (`Delete` also works).
- Search covers titles, tags, and text recognized on-device after each capture.
- Files live in `~/Library/Application Support/Snapok/History` (`Snapok Dev/History` for development builds), one folder per screenshot (`original.png`, `thumbnail.png`, `meta.json`). Screenshots older than the retention period (default 30 days) are deleted automatically.

### Settings and AI

Open **Settings…** (`⌘,`) or pick a settings page in the sidebar. **General** controls auto-save, retention (7/30/90 days or forever), and clearing the library. **Models** lists model providers: add any number, each with an API format (Anthropic Messages or OpenAI-compatible), base URL, API key (stored only in the Keychain), and model IDs; presets cover Anthropic, OpenAI, OpenRouter, DeepSeek, MiniMax, and Z.AI. Pick the default model that translation, questions, and auto naming use, test a provider's connection, and set the translation language. A key from earlier builds becomes an Anthropic provider automatically. **About** shows the version, project links, and the library and log locations.

| Feature | Runs | Needs API key |
| --- | --- | --- |
| Recognize text, search by text | On-device (Vision) | No |
| Mask sensitive information | On-device (Vision + pattern matching) | No |
| Translate, ask about a screenshot | Your default model | Yes |
| Auto title and tags (off by default) | Your default model | Yes |

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

While developing, `make dev` builds and launches Snapok Dev, then rebuilds and relaunches it whenever `Sources/`, `Resources/`, or `Package.swift` changes (install `fswatch` for event-based watching instead of polling). For a development executable, use `swift run Snapok`. For a Universal app, use:

```bash
./scripts/build-app.sh release --universal
```

### Development and release channels

Local builds default to the development channel; set `CHANNEL=release` for the release app. The two install side by side and never share data:

| | Development (default) | Release |
| --- | --- | --- |
| Build | `./scripts/build-app.sh release` | `CHANNEL=release ./scripts/build-app.sh release` |
| App | `dist/Snapok Dev.app`, DEV badge on the icon | `dist/Snapok.app` |
| Bundle identifier | `ai.thinkany.snapok.dev` | `ai.thinkany.snapok` |
| Screenshot library | `~/Library/Application Support/Snapok Dev/` | `~/Library/Application Support/Snapok/` |
| Settings / Keychain service | `ai.thinkany.snapok.dev` | `ai.thinkany.snapok` |
| Log | `~/Library/Logs/Snapok Dev.log` | `~/Library/Logs/Snapok.log` |
| Default capture hotkey | `⌥⇧A` | `⌃⌘A` |

The channel is stored as `SnapokChannel` in Info.plist; `swift run` counts as development. Each channel needs its own Screen Recording (and, for component focus, Accessibility) permission. On first launch, the development build moves the library, settings, and API key from pre-rename SnapAny builds into its own storage; the release build starts empty. Builds since 0.1.1 also copy settings and Keychain items from the 0.1.0 identifiers (`ai.snapok.mac`, `ai.snapok.mac.dev`); 0.1.0 installs can't update across the identifier change and need one manual reinstall.

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
./scripts/test-hotkey.sh
./scripts/test-models.sh
./scripts/test-updates.sh
```

`make test` runs them all.

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

Outputs are in `dist/archives/`. `PACKAGE_SUFFIX` controls the filename suffix and `BUILD_NUMBER` overrides the bundled build number. The workflow uploads artifacts and, for signed pushes, publishes to the CDN below; it does not create a GitHub Release.

## Updates

Signed builds from pushes are published to **https://cdn.snapok.app** (R2 bucket `snapok`) by `scripts/publish-cdn.sh`:

| Channel | Trigger | Manifest | Stable download |
| --- | --- | --- | --- |
| Snapok Dev | push to `dev` | `dev/latest.json` | `dev/Snapok-Dev.dmg` |
| Snapok | `v*` tag matching Info.plist | `latest.json` | `Snapok.dmg` |

Versioned packages are uploaded first and `latest.json` last, and the feed never moves to an older build. Release prereleases (`v1.2.0-beta.1`) upload packages without changing `latest.json`. Release notes come from the annotated tag message; development notes are the commit subject.

The app checks its channel's manifest 10 seconds after launch and every 6 hours (Settings → About → Updates, or *Check for Updates…* in the app and menu bar menus). It installs only after the ZIP matches the manifest's SHA-256 and the new app has the same bundle ID and version and is signed by the same Developer ID team, then replaces itself and relaunches. Local and ad-hoc builds are not Developer ID signed and never update.

CI uploads through the `snapok-cdn-upload` Worker (`cdn/`), which holds the bucket binding, using the `CDN_UPLOAD_TOKEN` secret, so the repository has no Cloudflare credentials. Without that secret, packaging still succeeds and the feed is left unchanged. To publish by hand with a local `wrangler` login: `CHANNEL=dev ./scripts/publish-cdn.sh dist/archives/<name>.dmg dist/archives/<name>.zip`.

## Contributing

Issues and pull requests are welcome. Branch from `dev`, keep changes focused, describe how to reproduce a bug, and run the relevant checks before submitting. For UI changes, include before/after screenshots and test at the minimum window size. Never include private screenshots or signing credentials in reports.

Source lives in `Sources/Snapok`, checks in `Tests/SnapokTests`, and build helpers in `scripts`. The current app icon can be regenerated with `scripts/render-icon.swift`; generated iconsets and earlier design drafts are excluded from Git.

## Language

Snapok starts in English by default. Choose **Settings → General → Language → 简体中文** to use Simplified Chinese. The choice is saved and applies immediately, without restarting, to menus, the library, settings, and every capture or editor opened afterwards; image editors and pinned images that are already open keep their language until reopened. AI answers and newly generated titles follow the app language; existing titles and the separate translation target are preserved.

## License

Snapok is licensed under [AGPL-3.0](LICENSE) © 2026 ThinkAny, LLC. A commercial license without
the AGPL's copyleft obligations is available — contact support@thinkany.ai.
