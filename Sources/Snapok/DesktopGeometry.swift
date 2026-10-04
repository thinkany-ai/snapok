import Foundation

/// AppKit desktop coordinates start at the main display's bottom-left; capture coordinates start at its top-left.
enum DesktopGeometry {
    static func captureRect(for desktopRect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: desktopRect.minX, y: primaryHeight - desktopRect.maxY,
               width: desktopRect.width, height: desktopRect.height)
    }

    static func pixelRect(for desktopRect: CGRect, bounds: CGRect, pixelSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scaleX = pixelSize.width / bounds.width
        let scaleY = pixelSize.height / bounds.height
        return CGRect(x: (desktopRect.minX - bounds.minX) * scaleX,
                      y: (bounds.maxY - desktopRect.maxY) * scaleY,
                      width: desktopRect.width * scaleX, height: desktopRect.height * scaleY).integral
    }
}
