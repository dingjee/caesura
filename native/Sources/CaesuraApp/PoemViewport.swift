import AppKit
import SwiftUI

/// The measurement of a poem body.
///
/// The window measures the body with CoreText: the size of the type decides
/// how much of the poem fits into the area it is drawn in, and a SwiftUI
/// `Text` does not report its wrapped height.
enum PoemBodyMetrics {
    /// The height of the wrapped text at the given face.
    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 0 else { return 0 }
        let rect = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(rect.height)
    }

    /// The height of the blocks of the body, with the spacing of the stack
    /// between them.
    static func height(of blocks: [NSAttributedString], spacing: CGFloat,
                       width: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        let heights = blocks.map { height(of: $0, width: width) }
        return heights.reduce(0, +) + spacing * CGFloat(blocks.count - 1)
    }
}

/// The layout of a poem body: the size of the type and the height of the body.
struct PoemBodyLayout {
    /// The size of the type (never below `PoemBodyLayout.minimumFontSize`).
    let fontSize: CGFloat
    /// The height of the whole body.
    let contentHeight: CGFloat
    /// True when the body does not fit into the area it is drawn in.
    let overflows: Bool
}

/// The size of a poem body.
///
/// The body is drawn with the size of the type scale, as long as it fits into
/// the area it is drawn in. A longer body is drawn with a smaller type — but
/// never with a type below 18 pt, which is the smallest size that is still
/// readable at a distance. A body that does not fit even then moves through
/// the window (see `PoemViewport`).
enum PoemBodyLayoutResolver {
    /// The smallest size the body is drawn with.
    static let minimumFontSize: CGFloat = 18
    /// The room the measurement keeps free: the wrapped height of a text and
    /// the height SwiftUI gives it may differ a little.
    private static let slack: CGFloat = 2

    /// The layout of a body of the given lines.
    static func resolve(lines: [String], natural: CGFloat, width: CGFloat, height: CGFloat,
                        spacing: CGFloat, font: @escaping (CGFloat) -> NSFont) -> PoemBodyLayout {
        let key = Key(text: lines.joined(separator: "\n"),
                      width: Int(width.rounded()), height: Int(height.rounded()),
                      natural: Int(natural.rounded()))
        return cache.layout(for: key) {
            measure(lines: lines, natural: natural, width: width, height: height,
                    spacing: spacing, font: font)
        }
    }

    private struct Key: Hashable {
        let text: String
        let width: Int
        let height: Int
        let natural: Int
    }

    private static func measure(lines: [String], natural: CGFloat, width: CGFloat,
                                height: CGFloat, spacing: CGFloat,
                                font: @escaping (CGFloat) -> NSFont) -> PoemBodyLayout {
        let measured: (CGFloat) -> CGFloat = { size in
            let blocks = lines.map {
                NSAttributedString(string: $0, attributes: [.font: font(size)])
            }
            return PoemBodyMetrics.height(of: blocks, spacing: spacing, width: width)
        }
        let naturalHeight = measured(natural)
        if naturalHeight + slack <= height {
            return PoemBodyLayout(fontSize: natural,
                                  contentHeight: naturalHeight + slack,
                                  overflows: false)
        }
        // The height of the body grows with the size of the type, so the
        // largest size that still fits is found by a binary search.
        var low = minimumFontSize
        var high = natural
        var fitted = minimumFontSize
        var fittedHeight = measured(minimumFontSize)
        while high - low > 0.25 {
            let middle = (low + high) / 2
            let middleHeight = measured(middle)
            if middleHeight + slack <= height {
                fitted = middle
                fittedHeight = middleHeight
                low = middle
            } else {
                high = middle
            }
        }
        if fittedHeight + slack <= height {
            return PoemBodyLayout(fontSize: fitted,
                                  contentHeight: fittedHeight + slack,
                                  overflows: false)
        }
        // Even the smallest size does not fit: the body moves through the
        // window.
        return PoemBodyLayout(fontSize: minimumFontSize,
                              contentHeight: fittedHeight + slack,
                              overflows: true)
    }

    private static let cache = PoemBodyLayoutCache()
}

/// The measured layouts of the bodies.
///
/// The window measures its body again on every tick of the break, so the
/// measurement is kept: the body of a break does not change while it is shown.
final class PoemBodyLayoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AnyHashable: PoemBodyLayout] = [:]
    private var order: [AnyHashable] = []
    private let limit = 8

    func layout(for key: AnyHashable, measure: () -> PoemBodyLayout) -> PoemBodyLayout {
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let layout = measure()
        lock.lock()
        entries[key] = layout
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return layout
    }
}

/// The window on the body of a poem.
///
/// The body is drawn in a frame of the height of the window. A body that is
/// longer than the frame moves through it (the way the lyrics of a song move
/// in a player), and the line that is cut at the top of the window fades out
/// instead of ending in the middle of a letter.
struct PoemViewport<Content: View>: View {
    /// The width the body is laid out in.
    let width: CGFloat
    /// The height of the window on the body.
    let height: CGFloat
    /// The height of the whole body.
    let contentHeight: CGFloat
    /// How far the body has moved up.
    let offset: CGFloat
    /// True when the body is cut at the top of the window.
    let fadesTop: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: .top)
            .frame(height: contentHeight, alignment: .top)
            .offset(y: -offset)
            .frame(height: height, alignment: .top)
            .clipped()
            .mask(topFade)
    }

    /// The fade at the top of the window.
    @ViewBuilder
    private var topFade: some View {
        if fadesTop, height > 0 {
            let fade = min(height * 0.16, 26)
            LinearGradient(
                gradient: Gradient(stops: [
                    Gradient.Stop(color: .white.opacity(0), location: 0),
                    Gradient.Stop(color: .white.opacity(0.5), location: fade / height * 0.5),
                    Gradient.Stop(color: .white, location: fade / height),
                    Gradient.Stop(color: .white, location: 1)
                ]),
                startPoint: .top, endPoint: .bottom)
        } else {
            Color.white
        }
    }
}
