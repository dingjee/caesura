import AppKit
import QuartzCore

/// The AppKit side of the radial reveal: the material mask that
/// `NSVisualEffectView.maskImage` builds out of the mask image of the wave.
///
/// The probe owns a window that is never ordered in — AppKit builds the
/// material mask of an effect view only when the view lives in a window — and
/// reads the mask layer out of the public layer tree of that view. Nothing is
/// shown, nothing is activated, no sound is played and no display is touched.
final class MaterialMaskProbe {
    private let window: NSWindow
    private let effectView: NSVisualEffectView

    init() {
        // The probe never shows anything: the application stays a background
        // application and can never take the focus away from the user.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.wantsLayer = true
        effectView = NSVisualEffectView(frame: window.contentView!.bounds)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        window.contentView!.addSubview(effectView)
    }

    /// The alpha of the material mask AppKit built from one mask image,
    /// rendered offscreen over a white host layer.
    ///
    /// The alpha of the result is the alpha of the mask as Core Animation
    /// applies it — the very mapping the blurred background of the break sees
    /// on screen.
    func materialMaskAlpha(for image: NSImage, bounds: CGRect,
                           pixels: CGSize) -> CGImage? {
        effectView.frame = CGRect(origin: .zero, size: bounds.size)
        effectView.maskImage = image
        window.contentView!.layoutSubtreeIfNeeded()
        // AppKit builds the material mask in the next run loop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        guard let maskLayer = materialMaskLayer() else { return nil }
        return render(maskLayer: maskLayer, bounds: bounds, pixels: pixels)
    }

    /// The alpha of the direct content mask of the break content: the same
    /// raster on the layer of the content host, as the app applies it.
    func contentMaskAlpha(cgImage: CGImage, bounds: CGRect,
                          pixels: CGSize) -> CGImage? {
        let host = CALayer()
        host.frame = bounds
        host.backgroundColor = NSColor.white.cgColor
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = cgImage
        mask.contentsGravity = .resize
        host.mask = mask
        return render(host: host, bounds: bounds, pixels: pixels)
    }

    /// The mask layer of the effect view: the one AppKit built for the mask
    /// image. Only public properties of the layer tree are read.
    private func materialMaskLayer() -> CALayer? {
        func find(_ layer: CALayer) -> CALayer? {
            if let mask = layer.mask, mask.contents != nil { return mask }
            for sublayer in layer.sublayers ?? [] {
                if let found = find(sublayer) { return found }
            }
            return nil
        }
        guard let root = window.contentView?.layer else { return nil }
        return find(root)
    }

    /// Renders a mask layer over a white host layer: the alpha of the result
    /// is the alpha of the mask.
    private func render(maskLayer: CALayer, bounds: CGRect,
                         pixels: CGSize) -> CGImage? {
        let host = CALayer()
        host.frame = bounds
        host.backgroundColor = NSColor.white.cgColor
        // A copy of the mask layer: the layer tree of AppKit is left alone and
        // only public properties of the mask are carried over.
        host.mask = copy(of: maskLayer)
        return render(host: host, bounds: bounds, pixels: pixels)
    }

    /// A copy of a mask layer with the public properties that decide how its
    /// contents are mapped onto the bounds.
    private func copy(of layer: CALayer) -> CALayer {
        let copy = CALayer()
        copy.frame = layer.frame
        copy.bounds = layer.bounds
        copy.contents = layer.contents
        copy.contentsCenter = layer.contentsCenter
        copy.contentsGravity = layer.contentsGravity
        copy.contentsScale = layer.contentsScale
        copy.isGeometryFlipped = layer.isGeometryFlipped
        return copy
    }

    private func render(host: CALayer, bounds: CGRect, pixels: CGSize) -> CGImage? {
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The layer is laid out in points, the context holds the pixels of the
        // frame: the whole layer is scaled into the context, so no part of it
        // falls outside.
        context.scaleBy(x: CGFloat(width) / bounds.width,
                        y: CGFloat(height) / bounds.height)
        host.render(in: context)
        return context.makeImage()
    }
}
