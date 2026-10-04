import AppKit

extension NSColorWell {
    /// Preserve the native anchored color popover while keeping the entry point a small swatch.
    @MainActor
    func useCompactSwatch() {
        colorWellStyle = .minimal
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
}
