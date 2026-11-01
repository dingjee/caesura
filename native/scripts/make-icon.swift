import AppKit
import Foundation

// The same two-slash mark as assets/caesura.svg, rendered without a browser.
guard CommandLine.arguments.count == 2 else { exit(2) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                           pixelsHigh: pixels, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 36 / 255, green: 75 / 255, blue: 75 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                     xRadius: 200, yRadius: 200).fill()
        NSColor(calibratedRed: 247 / 255, green: 241 / 255, blue: 223 / 255, alpha: 1).setStroke()
        let mark = NSBezierPath()
        for x in [330.0, 574.0] {
            mark.move(to: NSPoint(x: x, y: 334))
            mark.line(to: NSPoint(x: x + 120, y: 690))
        }
        mark.lineCapStyle = .round
        mark.lineWidth = 72
        mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
