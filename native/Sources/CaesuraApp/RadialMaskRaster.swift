import Foundation
import CoreGraphics

/// The bounded alpha raster behind the radial break reveal.
///
/// The raster is at most 256 px on its longest edge, whatever the window
/// size, and it is drawn for a handful of frames only (one ~600 ms entry
/// plus one ~400 ms exit per break) — never a per-frame full-screen bitmap.
/// Both mask consumers share one image per window per frame: the visual
/// effect view's documented `maskImage` and the identical layer mask on the
/// break content.
///
/// The alpha profile matches `RadialReveal.alpha`: fully opaque at and
/// inside `radius - feather`, falling linearly to fully clear at `radius`,
/// fully clear everywhere beyond it, and — when `radius` is 0 — fully clear
/// everywhere, so the hidden endpoint is exact and the window can be ordered
/// front without ever showing a raw frame.
///
/// This file is deliberately standalone (Foundation + CoreGraphics only, no
/// CaesuraCore import): the raster pixel probe compiles it together with a
/// tiny test main to assert the real pixels without opening any window.
enum RadialMaskRaster {
    /// The longest edge of the raster, in points. The window's aspect ratio
    /// is kept so the revealed disc stays a disc when the raster stretches
    /// back onto the window's bounds.
    static let maxEdge = 256.0

    /// The raster for one frame, or nil when `bounds` is empty.
    static func image(origin: CGPoint, radius: CGFloat, feather: CGFloat,
                      bounds: CGRect) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxEdge / max(bounds.width, bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        let clear = CGColor(colorSpace: space, components: [1, 1, 1, 0])!
        guard radius > 0 else {
            // The exact hidden endpoint: the whole raster stays clear. (A
            // zero-radius gradient would leave the outer region opaque.)
            context.setFillColor(clear)
            context.fill(localBounds)
            return context.makeImage()
        }
        // Raster pixels map onto the view's point coordinates (y up), exactly
        // like the view that carries the layer mask reads them.
        context.scaleBy(x: CGFloat(width) / bounds.width,
                        y: CGFloat(height) / bounds.height)
        // The centre of the disc is not yet fully opaque while the radius is
        // still inside the feather: the wave emerges out of the origin
        // instead of appearing as a hard dot. The profile is the one of
        // `RadialReveal.alpha`: opaque from `radius - feather` inwards, a
        // linear fall to clear at `radius`.
        let innerAlpha: CGFloat = feather > 0 ? min(1, radius / feather) : 1
        let inner = CGColor(colorSpace: space,
                            components: [1, 1, 1, innerAlpha])!
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: [inner, clear] as CFArray,
                                        locations: [0, 1]) else { return nil }
        // The first colour extends to the centre, nothing is drawn past the
        // end location: clear beyond `radius`.
        context.drawRadialGradient(gradient,
                                   startCenter: origin,
                                   startRadius: max(0, radius - feather),
                                   endCenter: origin,
                                   endRadius: radius,
                                   options: [.drawsBeforeStartLocation])
        return context.makeImage()
    }
}
