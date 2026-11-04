import Foundation

/// The visual reading focus of the poem of a break.
///
/// The focus decides how bright each shown line is; it never changes what is
/// revealed. The true frontier stays what the captured session committed:
/// scrolling, the slider, hovering and the focus itself never reveal a new
/// word, never switch the poem and never add a repetition.
///
/// The reading area of a break stands at the end of the poem, so the newest
/// words are the ones that are read: while the reading viewport follows the
/// poem, the line that holds the newest words is the focus. While the reader
/// reviews earlier lines, the focus follows the reading position itself: the
/// top of the poem reads at its first line, its end at its last one (see
/// `scrollAnchorY`). Old lines only step back visually — they are never
/// removed and a manual review restores their reading brightness.
public enum PoemFocus {
    /// The visual emphasis of a line that holds new words of this break but
    /// does not carry the frontier: it stays readable instead of sinking into
    /// the old context.
    public static let newWordLineOpacity: Double = 0.8
    /// About this long the handover of the brightness between lines takes.
    /// It is the shared token of the emphasis handover, so the line handover
    /// and the transition of the app cannot drift apart.
    public static let handoverMillis: Int64 = TransitionTokens.emphasisHandoverMillis

    /// The opacity of a line at a reading distance of `distanceRows` rows of
    /// type from the focus: the focus is clear, the line before it is still
    /// readable, and the brightness falls smoothly towards a floor it never
    /// drops below.
    public static func opacity(distanceRows: Double, increaseContrast: Bool = false) -> Double {
        let floor = increaseContrast ? PoemFocusCurve.contrastFloor : PoemFocusCurve.normalFloor
        let fall = max(0, 1 - floor)
        let value = floor + fall * exp(-PoemFocusCurve.decay * max(0, distanceRows))
        return min(max(value, 0), 1)
    }

    /// The line the reading anchor points at: the nearest line with words.
    /// Blank lines keep the spacing of the stanzas but are never a focus.
    public static func anchorLine(centers: [Double], hasWords: [Bool], anchorY: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for index in centers.indices where index < hasWords.count && hasWords[index] {
            let distance = abs(centers[index] - anchorY)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// The reading brightness of every line, given the y of the reading
    /// anchor in the coordinates of the document.
    ///
    /// `boostedLines` (only honoured while following, `boostedLineOpacity`
    /// non-nil) keep at least the given brightness: the lines that hold the
    /// new words of this break are not crushed into the old context.
    public static func opacities(centers: [Double], hasWords: [Bool], anchorY: Double,
                                 unitHeight: Double, increaseContrast: Bool = false,
                                 boostedLineOpacity: Double? = nil,
                                 boostedLines: Set<Int> = []) -> [Double] {
        guard unitHeight > 0 else { return centers.map { _ in 1 } }
        return centers.indices.map { index in
            var opacity: Double
            if index < hasWords.count, !hasWords[index] {
                // A blank line has no ink: its brightness does not matter.
                opacity = 1
            } else {
                opacity = self.opacity(distanceRows: abs(centers[index] - anchorY) / unitHeight,
                                       increaseContrast: increaseContrast)
            }
            if let boostedLineOpacity, boostedLines.contains(index) {
                opacity = max(opacity, boostedLineOpacity)
            }
            return min(max(opacity, 0), 1)
        }
    }

    /// The height of one row of type, from the measured heights of the lines:
    /// the smallest one (a wrapped line is never smaller than a row).
    public static func rowUnit(heights: [Double]) -> Double {
        heights.min() ?? 0
    }

    /// The reading anchor of a reading position: where the focus points when
    /// the reader is `fraction` of the way through the poem (0 at its top, 1
    /// at its end).
    ///
    /// The focus travels with the scroll: at the top of the poem it points at
    /// the first line with words, at its end at the last one, and in between
    /// it moves continuously between them. The blank lines of the stanzas
    /// keep their spacing but are never a focus, so the travel runs from the
    /// first line with words to the last one.
    ///
    /// The same mapping serves the review of a reader and the travel of the
    /// complete poem: both read at the position they are at, so the two never
    /// disagree about where the poem is read. A position outside the poem
    /// (the elastic overscroll of the scroller) clamps at the end it
    /// reached, and a body without a single word has no anchor at all.
    public static func scrollAnchorY(centers: [Double], hasWords: [Bool],
                                     fraction: Double) -> Double? {
        var first: Double?
        var last: Double?
        for index in centers.indices where index < hasWords.count && hasWords[index] {
            if first == nil { first = centers[index] }
            last = centers[index]
        }
        guard let first, let last else { return nil }
        let position = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return first + (last - first) * position
    }
}

/// The parameters of the focus falloff, in one place: a smooth exponential
/// curve through the reading targets — the focus at 1.0, the line before it
/// at about 0.55, two lines away at about 0.35 — levelling at a floor that
/// keeps the old context legible.
private enum PoemFocusCurve {
    /// The brightness a far line never falls below.
    static let normalFloor: Double = 0.22
    /// With increased contrast no large near-transparent text: the floor
    /// rises and the falloff is gentler.
    static let contrastFloor: Double = 0.45
    /// exp(-decay): the curve passes 0.55 one row away from the focus.
    static let decay: Double = 0.861
}

/// Which lines of the shown poem carry the newest words.
public struct PoemFocusMark: Equatable {
    /// The line of the newest revealed word (the frontier line). `-1` when
    /// the whole poem is shown and there is no frontier.
    public let frontierLine: Int
    /// The lines that hold words this break revealed (the frontier line
    /// included). Empty for the complete poem: its focus follows the travel.
    public let newWordLines: [Int]

    public init(frontierLine: Int, newWordLines: [Int]) {
        self.frontierLine = frontierLine
        self.newWordLines = newWordLines
    }

    /// The non-frontier lines that hold new words: they keep the secondary
    /// emphasis while the viewport follows the poem.
    public var secondaryLines: Set<Int> {
        Set(newWordLines.filter { $0 != frontierLine })
    }
}

public extension PoemBreakSession {
    /// The focus mark of the poem this break shows, in the line coordinates
    /// of its `preview`: while the poem grows, the frontier line and the
    /// lines that received new words; for the complete poem none.
    var focusMark: PoemFocusMark {
        guard mode == .revealing else { return PoemFocusMark(frontierLine: -1, newWordLines: []) }
        let preview = self.preview
        guard !preview.lines.isEmpty else { return PoemFocusMark(frontierLine: -1, newWordLines: []) }
        let words = PoemWords.words(in: lines)
        let firstNew = min(max(revealedBefore, 0), words.count)
        let lastNew = min(max(revealedAfter, firstNew), words.count)
        var newLines = Set<Int>()
        for word in words[firstNew..<lastNew] where word.lineIndex < preview.lines.count {
            newLines.insert(word.lineIndex)
        }
        let frontier = preview.softEdgeLineIndex
        let frontierInMark = frontier >= 0 && frontier < preview.lines.count
        if frontierInMark { newLines.insert(frontier) }
        return PoemFocusMark(frontierLine: frontierInMark ? frontier : -1,
                             newWordLines: newLines.sorted())
    }
}
