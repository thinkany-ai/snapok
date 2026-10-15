# Quick region OCR and text translation

These workflows complement Snapok's existing image OCR and image translation. **OCR Selected Area** extracts text only. The separate **Translate Selected Area** action recognizes and translates in one workflow; it returns translated text rather than replacing text inside the image.

## Quick region OCR

- Press **Control–Option–O**, or choose **OCR Selected Area** from the menu.
- Drag a region and release to recognize its text locally with Apple Vision. Press Escape to cancel capture.
- Screen Recording permission is required. OCR mode does not require component-snapping Accessibility permission.
- Formatting options: keep line breaks, smart paragraphs, or a single line. Smart paragraphs are heuristic; review the result for complex layouts, columns, and tables.

## Region translation

- Press **Control–Option–T**, or choose **Translate Selected Area** from the app/status menu.
- Drag a rectangle and release. Snapok recognizes its text locally, then translates it with the provider and target language from **Settings → OCR & Translation**.
- Escape cancels the selection. Screen Recording permission is required; Accessibility permission is not required for this workflow.
- The intermediate OCR text is not copied. Only a successful translation is delivered, using the existing automatic-copy, notification, sound and result-window preferences.
- Starting another OCR/translation action cancels the previous task's delivery, so stale results cannot overwrite newer ones.

## Library screenshot translation

- Right-click a single screenshot in the library and choose **Translate Screenshot Text**.
- Snapok re-runs local OCR on the current rendered screenshot, including saved annotations/redactions and styling. It does not use potentially stale cached OCR or a thumbnail, and does not read hidden text from the unredacted original.
- The screenshot and library metadata are not modified. Missing/unreadable files, empty recognition and translation failures leave the clipboard unchanged.
- Translating an existing screenshot does not require Screen Recording or Accessibility permission. Multiple selected screenshots do not show this action.
- This produces a text translation, not a translated image. Results use the same preferences and **Show Last OCR / Translation Result** entry as other text actions.

## Selected-text translation

- Select actual text in another application, then press **Control–Option–Shift–O**.
- Accessibility permission is required. The source application must expose selected text through Accessibility; images and some custom text controls do not.
- Choose a target language in **Settings → OCR & Translation**. Automatic targeting translates detected Chinese to English and other detected languages to Simplified Chinese.
- This action reads selected text, not a screenshot. It does not simulate Copy or replace the clipboard with the source text.

## Providers and privacy

- **Baidu Translate (default):** requires your own General Text Translation APP ID and matching secret, configured in settings. Selected or locally recognized text (not screenshot images) is sent to Baidu's HTTPS service when translation is invoked. Account quotas and charges may apply. This is not an offline translation mode. The adapter limits requests to 6,000 Unicode scalars; shorter passages are recommended.
- Credentials are stored together in the application's Keychain service, not in source code or ordinary preferences. The settings field does not reveal the saved secret. Connection testing makes a real request only when explicitly invoked.
- **System Translate:** this implementation requires macOS 26 or later and installed language packs. Use the explicit language-pack preparation control in settings. Translation uses the on-device strategy; language-pack preparation may require a download.
- Region OCR remains local regardless of the selected translation provider. No microphone permission is required for these workflows.

## Results and shortcuts

Automatic copying, side notices, and sound are enabled by default; automatically opening a result window is disabled. These options are independent. Successful results can be reviewed through **Show Last OCR / Translation Result**, including when automatic copying is disabled. Empty or failed recognition/translation does not overwrite the clipboard. A clipboard write failure is reported separately.

The editable result window supports formatting and restoring the original result. Shortcuts can be changed in **Settings → Shortcuts**.

## Tests and implementation notes

Run `bash scripts/test-ocr.sh` to compile the application sources with the OCR test entry point and run default-language and English test passes. The suite uses injected OCR and translation functions and isolated pasteboards for delivery checks; it does not validate live provider credentials, actual language-pack downloads, or cross-application permissions.

The region recognizer keeps bounding boxes to group lines, retain gaps, and order same-row fragments. This differs from the existing simple text scanner; future consolidation should preserve these layout semantics.

Manual release checks should cover multi-display capture, Escape cancellation, denied permissions, applications without accessible selections, live translation for both providers, shortcut conflicts, region translation, and library translation of edited/redacted screenshots. Automated tests do not establish live cross-application capture or provider success.
