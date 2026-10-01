# Automatic focus implementation

Window snapshots preserve front-to-back CGWindowList order and owner PID before the capture overlays appear. Hit tests target the underlying application explicitly, so the capture overlay does not become the focused component. AX results are converted from top-left display coordinates into Cocoa global coordinates, clipped to the captured window and current display, and arranged from the hit element to its containing regions.

Queries run on a serial actor with per-element messaging timeouts and bounded ancestor traversal. Mouse movement debounces requests by 45 ms. Generation checks, task cancellation, visibility, and selection-state checks reject obsolete results. No AX actions or target application content are modified.

Apple API references:
- https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout

Manual acceptance checks (requires granting Accessibility to the built SnapAny app):
1. Start capture over a native application. Move between toolbar buttons, content, and sidebar: the highlighted bounds should follow the accessible component.
2. Scroll up through parent regions to the window; scroll down to return. Hold Option to force the full window, release to resume component detection.
3. Click to lock a region; subsequent movement must not change it. Drag from the initial preview to create a custom selection. Right-click to reselect.
4. Move between overlapping applications and displays (including displays left/above the primary display); no stale result may replace the current preview.
5. Without permission, or on unsupported/custom-drawn content, whole-window selection and manual dragging remain usable.
6. Cancel while a slow app is being queried; no delayed selection may appear after cancelling or in a subsequent capture.

Automated geometry checks: run `./scripts/test-focus.sh`. This uses a standalone Swift test executable and does not require XCTest or a full Xcode installation.
