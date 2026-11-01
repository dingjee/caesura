import AppKit
import CaesuraCore

/// Draws the Caesura mark, pause state, progress and time directly in AppKit.
/// Renders template monochrome, paused state, progress ring and minutes number, with
/// dark-appearance-aware colors, following TrayIconDescriptor's decisions.
enum TrayIconRenderer {
    static func image(for descriptor: TrayIconDescriptor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let isTemplate = descriptor.monochrome
            let mainColor: NSColor
            if isTemplate {
                mainColor = .black
            } else if descriptor.darkAppearance {
                mainColor = NSColor(calibratedWhite: 0.92, alpha: 1)
            } else {
                mainColor = NSColor(calibratedWhite: 0.15, alpha: 1)
            }
            mainColor.setStroke()
            mainColor.setFill()

            switch descriptor.appearance {
            case .minutes(let minutes, let paused, _, _):
                draw(minutes: minutes, paused: paused, color: mainColor, rect: rect)
            case .progress(let percent, let paused, _, _):
                drawRing(progress: Double(percent) / 100.0, paused: paused, color: mainColor, rect: rect)
            case .icon(let paused, _, _):
                drawCaesuraGlyph(paused: paused, color: mainColor, rect: rect)
            }
            return true
        }
        image.isTemplate = descriptor.monochrome
        return image
    }

    /// The caesura mark is two slashes; vertical bars indicate a paused schedule.
    private static func drawCaesuraGlyph(paused: Bool, color: NSColor, rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if paused {
            let barWidth = rect.width * 0.16
            let barHeight = rect.height * 0.62
            let gap = rect.width * 0.1
            let left = NSRect(x: center.x - gap - barWidth, y: center.y - barHeight / 2, width: barWidth, height: barHeight)
            let right = NSRect(x: center.x + gap, y: center.y - barHeight / 2, width: barWidth, height: barHeight)
            color.setFill()
            NSBezierPath(roundedRect: left, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            NSBezierPath(roundedRect: right, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        } else {
            let path = NSBezierPath()
            for offset in [-0.17, 0.17] {
                let x = center.x + rect.width * offset
                path.move(to: NSPoint(x: x - rect.width * 0.10, y: rect.height * 0.22))
                path.line(to: NSPoint(x: x + rect.width * 0.10, y: rect.height * 0.78))
            }
            path.lineCapStyle = .round
            path.lineWidth = rect.width * 0.13
            color.setStroke()
            path.stroke()
        }
    }

    private static func draw(minutes: Int, paused: Bool, color: NSColor, rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: rect.height * (minutes >= 10 ? 0.68 : 0.78), weight: .medium),
            .foregroundColor: color
        ]
        let text = "\(minutes)"
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
        if paused {
            // Small underline marks the paused state in time mode.
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX + 2, y: 1.5))
            line.line(to: NSPoint(x: rect.maxX - 2, y: 1.5))
            line.lineWidth = 1.5
            color.setStroke()
            line.stroke()
        }
    }

    private static func drawRing(progress: Double, paused: Bool, color: NSColor, rect: NSRect) {
        let inset = rect.width * 0.12
        let ringRect = rect.insetBy(dx: inset, dy: inset)
        let background = NSBezierPath(ovalIn: ringRect)
        background.lineWidth = rect.width * 0.13
        color.withAlphaComponent(0.25).setStroke()
        background.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY),
                      radius: ringRect.width / 2,
                      startAngle: 90,
                      endAngle: 90 - 360 * max(0, min(1, progress)),
                      clockwise: true)
        arc.lineWidth = rect.width * 0.13
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        if paused {
            let barWidth = rect.width * 0.1
            color.setFill()
            NSBezierPath(rect: NSRect(x: rect.midX - barWidth * 1.6, y: rect.midY - rect.height * 0.18,
                                      width: barWidth, height: rect.height * 0.36)).fill()
            NSBezierPath(rect: NSRect(x: rect.midX + barWidth * 0.6, y: rect.midY - rect.height * 0.18,
                                      width: barWidth, height: rect.height * 0.36)).fill()
        }
    }
}
