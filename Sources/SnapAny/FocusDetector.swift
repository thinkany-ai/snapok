import AppKit
import ApplicationServices

struct WindowTarget: Sendable {
    let frame: CGRect
    let pid: pid_t
}

/// Coordinates from AX and CGWindowList use the primary display's top-left origin.
enum FocusGeometry {
    static func cocoaRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
        if let value = attribute(hit, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
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
               let candidate = FocusGeometry.candidate(frame, in: target.frame, at: point),
               candidate.width < target.frame.width - 2 || candidate.height < target.frame.height - 2 {
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
