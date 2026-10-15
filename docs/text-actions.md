# Quick region OCR and selected-text translation

These workflows complement Snapok's existing image OCR and image translation. Region OCR extracts text; it does **not** automatically translate the captured region.

## Quick region OCR

- Press **Control–Option–O**, or choose **OCR Selected Area** from the menu.
- Drag a region and release to recognize its text locally with Apple Vision. Press Escape to cancel capture.
- Screen Recording permission is required. OCR mode does not require component-snapping Accessibility permission.
- Formatting options: keep line breaks, smart paragraphs, or a single line. Smart paragraphs are heuristic; review the result for complex layouts, columns, and tables.

## Selected-text translation

- Select actual text in another application, then press **Control–Option–Shift–O**.
- Accessibility permission is required. The source application must expose selected text through Accessibility; images and some custom text controls do not.
- Choose a target language in **Settings → OCR & Translation**. Automatic targeting translates detected Chinese to English and other detected languages to Simplified Chinese.
- This action reads selected text, not a screenshot. It does not simulate Copy or replace the clipboard with the source text.

## Providers and privacy

- **Baidu Translate (default):** requires your own General Text Translation APP ID and matching secret, configured in settings. Selected text is sent to Baidu's HTTPS service when translation is invoked. Account quotas and charges may apply. This is not an offline translation mode. The adapter limits requests to 6,000 Unicode scalars; shorter passages are recommended.
- Credentials are stored together in the application's Keychain service, not in source code or ordinary preferences. The settings field does not reveal the saved secret. Connection testing makes a real request only when explicitly invoked.
- **System Translate:** this implementation requires macOS 26 or later and installed language packs. Use the explicit language-pack preparation control in settings. Translation uses the on-device strategy; language-pack preparation may require a download.
- Region OCR remains local regardless of the selected translation provider. No microphone permission is required for either workflow.

## Results and shortcuts

Automatic copying, side notices, and sound are enabled by default; automatically opening a result window is disabled. These options are independent. Successful results can be reviewed through **Show Last OCR / Translation Result**, including when automatic copying is disabled. Empty or failed recognition/translation does not overwrite the clipboard. A clipboard write failure is reported separately.

The editable result window supports formatting and restoring the original result. Shortcuts can be changed in **Settings → Shortcuts**.

## Tests and implementation notes

Run `bash scripts/test-ocr.sh` to compile the application sources with the OCR test entry point and run default-language and English test passes. The suite uses injected translation functions and isolated pasteboards for delivery checks; it does not validate live provider credentials, actual language-pack downloads, or cross-application permissions.

The region recognizer keeps bounding boxes to group lines, retain gaps, and order same-row fragments. This differs from the existing simple text scanner; future consolidation should preserve these layout semantics.

Manual release checks should cover multi-display capture, Escape cancellation, denied permissions, applications without accessible selections, live translation for both providers, and shortcut conflicts.
