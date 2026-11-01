import AppKit

/// Renders an app window into a PNG image.
///
/// The window surface that `CGWindowListCreateImage` returns does not always contain
/// the drawn content of a non-activating overlay window, so the view hierarchy is
/// rendered into a bitmap instead. The result is a real render of the app's own
/// window (no screen recording permission needed, no other application involved).
enum BreakWindowRenderer {
    static func render(_ view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
