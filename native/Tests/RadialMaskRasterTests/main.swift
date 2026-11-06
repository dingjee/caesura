import AppKit
import QuartzCore

var checks = 0
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
    let data = image.dataProvider!.data! as Data
    return Int(data[(image.height - 1 - y) * image.bytesPerRow + x * 4 + 3])
}
let bounds = CGRect(x: 0, y: 0, width: 256, height: 128)
let origin = CGPoint(x: 64, y: 24)
let mask = RadialMaskRaster.image(origin: origin, radius: 40, feather: 16, bounds: bounds)!
// CGImage rows start at the top; verify the sampling helper against a
// reference Quartz fill in the same y-up coordinates as the content host.
let reference = CGContext(data:nil,width:256,height:128,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
reference.setFillColor(NSColor.white.cgColor)
reference.fill(CGRect(x:60,y:20,width:8,height:8))
expect(alpha(reference.makeImage()!,64,24) == 255, "pixel sampler matches Quartz y-up coordinates")
expect(alpha(mask, 64, 24) == 255, "inside disc is opaque")
expect(alpha(mask, 200, 24) == 0, "outside disc is clear")
expect(alpha(mask, 96, 24) > 70 && alpha(mask, 96, 24) < 180, "edge is feathered")
expect(alpha(mask, 64, 104) == 0, "off-centre y stays asymmetric")
let hidden = RadialMaskRaster.image(origin: origin, radius: 0, feather: 16, bounds: bounds)!
let hiddenData = hidden.dataProvider!.data! as Data
expect(stride(from: 3, to: hiddenData.count, by: 4).allSatisfy { hiddenData[$0] == 0 }, "hidden endpoint fully clear")
let full = RadialMaskRaster.image(origin: origin, radius: 280, feather: 16, bounds: bounds)!
expect([(0,0),(255,0),(0,127),(255,127)].allSatisfy { alpha(full, $0.0, $0.1) == 255 }, "full endpoint covers all corners")
let early = RadialMaskRaster.image(origin: origin, radius: 8, feather: 16, bounds: bounds)!
expect(alpha(early, 64, 24) > 70 && alpha(early, 64, 24) < 160, "early centre emerges softly")
let large = RadialMaskRaster.image(origin: origin, radius: 100, feather: 48, bounds: CGRect(x:0,y:0,width:7680,height:2160))!
expect(max(large.width, large.height) <= 256, "raster allocation bounded")

// The wave of a real window: the raster stays bounded while the window is
// much larger, so the plan radius is measured in points and the scaled CTM
// maps it onto the small raster. The corner of the window sits exactly one
// feather inside the radius, so at the full endpoint every corner pixel must
// be fully opaque — a pixel that is not would show a leftover of the desktop
// at the edge of the window (the reported corner residue).
func furthestCornerDistance(origin: CGPoint, bounds: CGRect) -> CGFloat {
    let corners = [CGPoint(x: bounds.minX, y: bounds.minY),
                   CGPoint(x: bounds.maxX, y: bounds.minY),
                   CGPoint(x: bounds.minX, y: bounds.maxY),
                   CGPoint(x: bounds.maxX, y: bounds.maxY)]
    return corners.map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
}
let realBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let feather: CGFloat = 48
let realOrigin = CGPoint(x: 480, y: 240) // a plausible pointer position, y up
let realRadius = furthestCornerDistance(origin: realOrigin, bounds: realBounds) + feather
let realFull = RadialMaskRaster.image(origin: realOrigin, radius: realRadius,
                                      feather: feather, bounds: realBounds)!
expect(realFull.height == 144, "a 1920×1080 window raster stays at 256×144")
expect([(0, 0), (255, 0), (0, 143), (255, 143)].allSatisfy {
    alpha(realFull, $0.0, $0.1) == 255
}, "full endpoint of a real window covers every corner pixel")
// The reported symptom is a leftover at the top right corner: sample the
// pixels of that corner region at the full endpoint directly.
let topRightRegion = (246...255).flatMap { x in (134...143).map { (x, $0) } }
expect(topRightRegion.allSatisfy { alpha(realFull, $0.0, $0.1) == 255 },
       "the top right corner region is fully opaque at the full endpoint")
// And at the hidden endpoint the same region stays fully clear.
let realHidden = RadialMaskRaster.image(origin: realOrigin, radius: 0,
                                        feather: feather, bounds: realBounds)!
let realHiddenData = realHidden.dataProvider!.data! as Data
expect(stride(from: 3, to: realHiddenData.count, by: 4).allSatisfy { realHiddenData[$0] == 0 },
       "hidden endpoint of a real window is fully clear")
// The wave at nine tenths of the plan: the far corner is still hidden — the
// mask there is clear, not a leftover of the previous content.
let almostFull = RadialMaskRaster.image(origin: realOrigin, radius: realRadius * 0.9,
                                        feather: feather, bounds: realBounds)!
expect(alpha(almostFull, 255, 143) == 0, "the far corner stays hidden until the wave reaches it")
// Render the actual CALayer mask offscreen to verify image orientation in
// the non-flipped host coordinate system without ordering any window front.
let host = CALayer()
host.frame = bounds
host.backgroundColor = NSColor.white.cgColor
let layerMask = CALayer()
layerMask.frame = bounds
layerMask.contents = mask
layerMask.contentsGravity = .resize
host.mask = layerMask
let context = CGContext(data:nil,width:256,height:128,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
host.render(in: context)
let rendered = context.makeImage()!
expect(alpha(rendered,64,24) > 240 && alpha(rendered,64,104) == 0, "CALayer mask shares non-flipped origin")

// ---------------------------------------------------------------------------
// The material mask of the real consumer: NSVisualEffectView.maskImage.
//
// The wave masks the blurred material through the documented `maskImage` of
// the effect view. AppKit does not draw that image itself: it builds a mask
// layer out of it and maps the raster onto the bounds of the effect view
// through the `contentsCenter` of that layer — the centre part of the 3x3
// grid that scales the image. AppKit derives that centre from the *cap
// insets* of the image, and an image without cap insets leaves the centre
// degenerate, so the raster is not mapped onto the bounds at all: the
// blurred background is revealed wrongly (the strips and the misplaced head
// of the reported bug).
//
// The checks below render the mask layer AppKit itself builds and compare it
// with the direct content mask of the break content: both have to reveal the
// very same disc at the very same place. The probe owns a window that is
// never ordered in — nothing is shown, activated or played.
// ---------------------------------------------------------------------------
let probe = MaterialMaskProbe()

/// The alpha channel of an image, row by row, in the y-up coordinates of the
/// content host (the first row of the image is the top one).
func alphaValues(_ image: CGImage) -> [Int] {
    let data = image.dataProvider!.data! as Data
    var values: [Int] = []
    values.reserveCapacity(image.width * image.height)
    for y in 0..<image.height {
        for x in 0..<image.width {
            values.append(Int(data[(image.height - 1 - y) * image.bytesPerRow + x * 4 + 3]))
        }
    }
    return values
}
func highestAlpha(_ image: CGImage) -> Int { alphaValues(image).max() ?? 0 }
func lowestAlpha(_ image: CGImage) -> Int { alphaValues(image).min() ?? 0 }
/// The mean difference of the alpha of two masks of the same size.
func meanAlphaDifference(_ a: CGImage, _ b: CGImage) -> Double {
    let first = alphaValues(a), second = alphaValues(b)
    guard first.count == second.count, !first.isEmpty else { return 255 }
    let total = zip(first, second).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
    return total / Double(first.count)
}
/// The pixels where the material mask and the content mask disagree: the
/// material may not show anything where the wave has not reached yet (a
/// strip) and may not hide anything where the wave already arrived.
func disagreements(_ material: CGImage, _ content: CGImage) -> (outside: Int, inside: Int) {
    let mask = alphaValues(material), wave = alphaValues(content)
    guard mask.count == wave.count else { return (wave.count, wave.count) }
    var outside = 0, inside = 0
    for (masked, revealed) in zip(mask, wave) {
        if revealed <= 8, masked > 40 { outside += 1 }
        if revealed >= 247, masked < 215 { inside += 1 }
    }
    return (outside, inside)
}

/// One frame of the wave on one window.
struct MaskCase {
    let label: String
    let bounds: CGRect
    let origin: CGPoint
    let radius: CGFloat
    let feather: CGFloat
}
/// The distance from the centre of the wave to the furthest corner.
func cornerDistance(origin: CGPoint, bounds: CGRect) -> CGFloat {
    let corners = [CGPoint(x: bounds.minX, y: bounds.minY),
                   CGPoint(x: bounds.maxX, y: bounds.minY),
                   CGPoint(x: bounds.minX, y: bounds.maxY),
                   CGPoint(x: bounds.maxX, y: bounds.maxY)]
    return corners.map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
}

let wideBounds = CGRect(x: 0, y: 0, width: 960, height: 540)
let tallBounds = CGRect(x: 0, y: 0, width: 540, height: 960)
let wideOrigin = CGPoint(x: 140, y: 110)      // the disc in the lower left
let farOrigin = CGPoint(x: 820, y: 430)       // the disc near the right top
let wideFeather: CGFloat = 48
let maskCases: [MaskCase] = [
    MaskCase(label: "wide window, disc in the lower left", bounds: wideBounds,
             origin: wideOrigin, radius: 220, feather: wideFeather),
    MaskCase(label: "wide window, disc near the right top", bounds: wideBounds,
             origin: farOrigin, radius: 220, feather: wideFeather),
    MaskCase(label: "tall window, disc in the lower left", bounds: tallBounds,
             origin: CGPoint(x: 120, y: 160), radius: 220, feather: wideFeather),
    MaskCase(label: "twice the raster resolution", bounds: CGRect(x: 0, y: 0, width: 512, height: 288),
             origin: CGPoint(x: 100, y: 90), radius: 130, feather: 24),
    MaskCase(label: "the resolution of the raster itself", bounds: CGRect(x: 0, y: 0, width: 256, height: 144),
             origin: CGPoint(x: 64, y: 40), radius: 70, feather: 16),
]
for maskCase in maskCases {
    guard let raster = RadialMaskRaster.image(origin: maskCase.origin,
                                              radius: maskCase.radius,
                                              feather: maskCase.feather,
                                              bounds: maskCase.bounds) else {
        expect(false, "\(maskCase.label): the raster of the frame exists")
        continue
    }
    let pixels = CGSize(width: raster.width, height: raster.height)
    // The mask image of the production code, not a copy of it.
    let maskImage = RadialMaskImage.make(cgImage: raster, size: maskCase.bounds.size)
    guard let material = probe.materialMaskAlpha(for: maskImage,
                                                 bounds: maskCase.bounds,
                                                 pixels: pixels),
          let content = probe.contentMaskAlpha(cgImage: raster,
                                               bounds: maskCase.bounds,
                                               pixels: pixels) else {
        expect(false, "\(maskCase.label): both masks can be rendered")
        continue
    }
    // The blurred material has to follow the poem: the disc of the wave must
    // be visible in the material mask, not an empty or misplaced mask.
    expect(highestAlpha(material) >= 200,
           "\(maskCase.label): the material mask reveals the disc of the wave")
    // And both masks have to agree: the same disc at the same place, so the
    // backdrop and the poem arrive together.
    expect(meanAlphaDifference(material, content) <= 24,
           "\(maskCase.label): the material mask and the content mask agree")
    // No strip: the material stays hidden where the wave has not arrived yet
    // and stays visible where it already arrived.
    let strip = disagreements(material, content)
    expect(strip.outside == 0,
           "\(maskCase.label): the material shows no strip outside the wave")
    expect(strip.inside == 0,
           "\(maskCase.label): the material hides nothing inside the wave")
}

// The two endpoints of the wave, on a wide window with the disc in the lower
// left: the material is fully hidden at the start and fully shown at the end.
let endpointOrigin = wideOrigin
let endpointFeather = wideFeather
let hiddenRadius: CGFloat = 0
let fullRadius = cornerDistance(origin: endpointOrigin, bounds: wideBounds) + endpointFeather
for endpoint in [(label: "hidden endpoint", radius: hiddenRadius),
                 (label: "full endpoint", radius: fullRadius)] {
    guard let raster = RadialMaskRaster.image(origin: endpointOrigin,
                                              radius: endpoint.radius,
                                              feather: endpointFeather,
                                              bounds: wideBounds) else {
        expect(false, "\(endpoint.label): the raster of the frame exists")
        continue
    }
    let pixels = CGSize(width: raster.width, height: raster.height)
    let maskImage = RadialMaskImage.make(cgImage: raster, size: wideBounds.size)
    guard let material = probe.materialMaskAlpha(for: maskImage,
                                                 bounds: wideBounds,
                                                 pixels: pixels),
          let content = probe.contentMaskAlpha(cgImage: raster,
                                               bounds: wideBounds,
                                               pixels: pixels) else {
        expect(false, "\(endpoint.label): both masks can be rendered")
        continue
    }
    if endpoint.radius == 0 {
        expect(highestAlpha(material) == 0 && highestAlpha(content) == 0,
               "\(endpoint.label): the material and the content stay hidden")
    } else {
        expect(lowestAlpha(material) == 255 && lowestAlpha(content) == 255,
               "\(endpoint.label): the material and the content are fully shown")
    }
}
if failures == 0 { print("PASS: \(checks) radial raster, offscreen layer and AppKit material mask checks; no window was ever shown") }

print("failures=\(failures)")
exit(failures == 0 ? 0 : 1)
