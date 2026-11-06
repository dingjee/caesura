import AppKit
import CoreGraphics

/// The material mask image of the radial break reveal.
///
/// `NSVisualEffectView.maskImage` does not draw the image itself: AppKit
/// turns it into a Core Animation mask layer and maps the image onto the
/// bounds of the effect view through the `contentsCenter` of that layer,
/// which AppKit derives from the *cap insets* of the image. An image without
/// cap insets — `NSImage(cgImage:size:)` has none — leaves that centre
/// degenerate (an empty rect), so Core Animation has no stretchable region,
/// cannot place the raster and reveals the blurred material wrongly: the
/// strips and the misplaced head of the reported bug.
///
/// The cap insets below are one point wide and only give AppKit the
/// stretchable region it asks for: the raster still covers the whole bounds,
/// the disc stays at the same global point as the content mask and the
/// allocation stays bounded (at most 256 px on the longest edge).
enum RadialMaskImage {
    /// The width of the cap insets, in points.
    static let capInset: CGFloat = 1

    /// The mask image of one frame of the wave.
    ///
    /// - Parameters:
    ///   - cgImage: the bounded alpha raster of the frame.
    ///   - size: the logical size of the image: the bounds of the effect view.
    static func make(cgImage: CGImage, size: CGSize) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: size)
        // The insets have to stay inside the image: a very small effect view
        // gets a proportionally smaller inset.
        let shortest = min(size.width, size.height)
        let inset = shortest > 0 ? min(capInset, shortest / 4) : capInset
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        return image
    }
}
