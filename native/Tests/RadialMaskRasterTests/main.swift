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
if failures == 0 { print("PASS: \(checks) radial raster and offscreen layer checks; no windows shown") }

print("failures=\(failures)")
exit(failures == 0 ? 0 : 1)
