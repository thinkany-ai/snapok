import AppKit
import ApplicationServices

struct WindowTarget: Sendable {
    let frame: CGRect
    let pid: pid_t
    var isSystemUI = false
    var containerFrame: CGRect? = nil

    var selectionFrame: CGRect { containerFrame ?? frame }
}

/// Coordinates from AX and CGWindowList use the primary display's top-left origin.
enum FocusGeometry {
    static func cocoaRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The strip a visible Dock reserves on a display, from the gap between its frame and visibleFrame.
    /// Used when Accessibility is unavailable: newer macOS reports the Dock window as the whole display.
    /// An auto-hidden Dock reserves only a few points and is ignored.
    static func reservedDockArea(screen: CGRect, visible: CGRect) -> CGRect? {
        let minimum: CGFloat = 20
        let bottom = visible.minY - screen.minY
        let left = visible.minX - screen.minX
        let right = screen.maxX - visible.maxX
        if bottom >= minimum { return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: bottom) }
        if left >= minimum { return CGRect(x: screen.minX, y: visible.minY, width: left, height: visible.height) }
        if right >= minimum { return CGRect(x: visible.maxX, y: visible.minY, width: right, height: visible.height) }
        return nil
    }

    static func dockRegion(_ frame: CGRect, on screen: CGRect) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.width >= 18, frame.height >= 18 else { return nil }
        let visible = frame.intersection(screen)
        guard !visible.isNull, visible.width >= 18, visible.height >= 18,
              // Reject full-display compositor surfaces, including Mission Control.
              visible.width < screen.width * 0.8 || visible.height < screen.height * 0.8 else { return nil }
        return visible.insetBy(dx: -8, dy: -8).intersection(screen)
    }

    static func candidate(_ frame: CGRect, in window: CGRect, at point: CGPoint) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else { return nil }
        let clipped = frame.intersection(window)
        guard !clipped.isNull, clipped.width >= 18, clipped.height >= 18,
              clipped.contains(point) else { return nil }
        return clipped
    }
}

/// AX messaging runs away from the main actor so unresponsive apps cannot freeze selection.
actor FocusDetector {
    static let shared = FocusDetector()

    func regions(in target: WindowTarget, at point: CGPoint, primaryHeight: CGFloat) -> [CGRect] {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var hit: AXUIElement?
        // Query the underlying application, not the system-wide element: our overlay is topmost.
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(primaryHeight - point.y), &hit) == .success,
              let hit else { return [] }
        // Reject a hit from another window of the same process.
        if !target.isSystemUI, let value = attribute(hit, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
           let windowFrame = frame(of: value as! AXUIElement, primaryHeight: primaryHeight),
           abs(windowFrame.minX - target.frame.minX) > 4 || abs(windowFrame.minY - target.frame.minY) > 4 {
            return []
        }
        let deadline = Date().addingTimeInterval(0.3)
        var current: AXUIElement? = hit
        var visited: [AXUIElement] = []
        var frames: [CGRect] = []
        for _ in 0..<20 {
            guard !Task.isCancelled, Date() < deadline, let element = current,
                  !visited.contains(where: { CFEqual($0, element) }) else { break }
            visited.append(element)
            if let frame = frame(of: element, primaryHeight: primaryHeight),
               let candidate = FocusGeometry.candidate(frame, in: target.selectionFrame, at: point),
               candidate.width < target.selectionFrame.width - 2 || candidate.height < target.selectionFrame.height - 2 {
                // Each subsequent candidate must contain the preceding region.
                if !frames.contains(candidate), frames.last.map({ candidate.contains($0) }) ?? true {
                    frames.append(candidate)
                }
            }
            if (attribute(element, kAXRoleAttribute) as? String) == kAXWindowRole { break }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return frames
    }

    /// Dock's compositor window can cover the entire screen. AXList describes its visible content.
    func dockFrames(pid: pid_t, primaryHeight: CGFloat) -> [CGRect] {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return [] }
        let app = AXUIElementCreateApplication(pid)
        guard let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.prefix(20).compactMap { child in
            guard attribute(child, kAXRoleAttribute) as? String == kAXListRole else { return nil }
            return frame(of: child, primaryHeight: primaryHeight)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func frame(of element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = position as! AXValue
        let s = size as! AXValue
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
        return FocusGeometry.cocoaRect(CGRect(origin: origin, size: dimensions), primaryHeight: primaryHeight)
    }
}

@MainActor
enum WindowDetector {
    /// Snapshot before overlays appear, preserving compositor order and the original menu owner.
    static func visibleWindowFrames() async -> [WindowTarget] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let menuPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? ownPID
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let dockFrames: [CGRect]
        if let dockPID {
            dockFrames = await FocusDetector.shared.dockFrames(pid: dockPID, primaryHeight: primaryHeight)
        } else {
            dockFrames = []
        }
        func bounds(_ entry: [String: Any]) -> CGRect? {
            guard ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else { return nil }
            return FocusGeometry.cocoaRect(rect, primaryHeight: primaryHeight)
        }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let menuBars = info.compactMap { entry -> CGRect? in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == menuLevel,
                  let rect = bounds(entry), rect.width >= 100, rect.height >= 18, rect.height <= 100,
                  screens.contains(where: { abs($0.maxY - rect.maxY) <= 2 }) else { return nil }
            return rect
        }
        var result: [WindowTarget] = []
        for entry in info {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let rect = bounds(entry) else { continue }
            if layer == menuLevel, menuBars.contains(rect) {
                result.append(WindowTarget(frame: rect, pid: menuPID, isSystemUI: true))
            } else if layer == statusLevel, rect.width >= 18, rect.height >= 18,
                      let bar = menuBars.first(where: { $0.contains(rect) }) {
                result.append(WindowTarget(frame: rect, pid: pid, isSystemUI: true, containerFrame: bar))
            } else if layer == dockLevel, pid == dockPID {
                // Prefer exact AX bounds. Without Accessibility, use older macOS's CG bounds when they are
                // Dock-sized, otherwise the strip the Dock reserves (newer macOS reports a full-display window).
                let reserved = NSScreen.screens.compactMap { FocusGeometry.reservedDockArea(screen: $0.frame, visible: $0.visibleFrame) }
                let frames = !dockFrames.isEmpty ? dockFrames : screens.contains(where: { FocusGeometry.dockRegion(rect, on: $0) != nil }) ? [rect] : reserved
                for frame in frames {
                    for screen in screens {
                        if let region = FocusGeometry.dockRegion(frame, on: screen),
                           !result.contains(where: { $0.pid == pid && $0.frame == region }) {
                            result.append(WindowTarget(frame: region, pid: pid, isSystemUI: true))
                        }
                    }
                }
            } else if layer == 0, rect.width >= 40, rect.height >= 40 {
                // Our own library and editor windows are capturable too; the capture overlay is not on screen yet.
                result.append(WindowTarget(frame: rect, pid: pid))
            }
        }
        return result
    }
}
