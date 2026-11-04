import Foundation
import CaesuraCore

enum PoemFocusTests {
    static func registerAll() {
        TestRunner.register("poem focus: the curve falls smoothly from the focus to its floor", curveFalloff)
        TestRunner.register("poem focus: increased contrast keeps far lines readable", curveIncreaseContrast)
        TestRunner.register("poem focus: the anchor is the nearest line with words", anchorSkipsBlankLines)
        TestRunner.register("poem focus: real poem lines decide what can be a focus", realTextLinesAreFocusable)
        TestRunner.register("poem focus: brightness falls with the reading distance", opacitiesFallWithDistance)
        TestRunner.register("poem focus: lines with new words keep their secondary emphasis", newWordLinesStayReadable)
        TestRunner.register("poem focus: the boost is a following rule, not a review rule", boostOnlyWhileFollowing)
        TestRunner.register("poem focus: the row unit is the smallest measured line", rowUnitIsTheSmallestLine)
        TestRunner.register("poem focus: the scroll reads the top of the poem at the top and its end at the end", scrollAnchorReadsTheEnds)
        TestRunner.register("poem focus: the reading anchor travels with the scroll", scrollAnchorTravelsContinuously)
        TestRunner.register("poem focus: an overscroll past the ends clamps", scrollAnchorClamps)
        TestRunner.register("poem focus: an empty, a single-line and a short body stay safe", scrollAnchorStaysSafe)
        TestRunner.register("poem focus: the frontier and the new-word lines are marked", focusMarkOfASession)
        TestRunner.register("poem focus: the complete poem has no frontier mark", focusMarkOfTheCompletePoem)
        TestRunner.register("poem focus: scrolling never moves the reveal", focusNeverTouchesTheReveal)
    }

    // MARK: Helpers

    static func makePoem(id: String = "p1", lines: [String]) -> Poem {
        Poem(id: id, title: "Test Poem", author: "Test Author", lines: lines,
             excerpt: Array(lines.prefix(2)), seasons: [], months: [],
             authorBorn: nil, authorDied: nil, source: "test")
    }

    static func revealing(_ poem: Poem, mini: Bool = true, revealedBefore: Int) -> PoemBreakSession {
        PoemBreakSession.revealing(poem: poem, mini: mini, startedAt: 1_000,
                                   durationMillis: mini ? 3_000 : 5_000,
                                   revealedBefore: revealedBefore)
    }

    /// Five real lines, one blank between the stanzas, centres one row apart.
    static let centers: [Double] = [0.5, 1.5, 2.5, 3.5, 5.5, 6.5]
    static let hasWords: [Bool] = [true, true, true, true, false, true]

    /// A body with a leading stanza break, a wrapped line (a taller row), a
    /// stanza break in the middle and trailing blanks: only the lines with
    /// words are ever a focus, and their rows are not of one height.
    static let scrolledCenters: [Double] = [10, 30, 60, 100, 160, 190]
    static let scrolledHasWords: [Bool] = [false, true, false, true, false, false]

    // MARK: The falloff curve

    /// The focus is clear, the line before it is still readable, two lines
    /// away it steps back, and far lines never fall below the floor.
    static func curveFalloff() throws {
        try expectEqual(PoemFocus.opacity(distanceRows: 0), 1)
        let one = PoemFocus.opacity(distanceRows: 1)
        try expectTrue(one > 0.5 && one < 0.6, "the line before the focus stays readable, got \(one)")
        let two = PoemFocus.opacity(distanceRows: 2)
        try expectTrue(two > 0.3 && two < 0.4, "two lines away steps back, got \(two)")
        var previous = 1.0
        for step in stride(from: 0.0, through: 8.0, by: 0.25) {
            let value = PoemFocus.opacity(distanceRows: step)
            try expectTrue(value <= previous + 1e-9, "the falloff never gets brighter at \(step)")
            try expectTrue(value >= 0.2, "the normal floor is ~0.20, got \(value) at \(step)")
            previous = value
        }
        let far = PoemFocus.opacity(distanceRows: 100)
        try expectTrue(far >= 0.2 && far < 0.3, "far lines level at the floor, got \(far)")
        // A negative distance (never asked for, but clamped) behaves like 0.
        try expectEqual(PoemFocus.opacity(distanceRows: -3), 1)
    }

    /// With increased contrast the floor rises: no large near-transparent
    /// text stays behind the focus.
    static func curveIncreaseContrast() throws {
        try expectTrue(PoemFocus.opacity(distanceRows: 0, increaseContrast: true) <= 1)
        let one = PoemFocus.opacity(distanceRows: 1, increaseContrast: true)
        try expectTrue(one > 0.6, "contrast keeps the neighbours readable, got \(one)")
        var previous = 1.0
        for step in stride(from: 0.0, through: 8.0, by: 0.25) {
            let value = PoemFocus.opacity(distanceRows: step, increaseContrast: true)
            try expectTrue(value <= previous + 1e-9, "the contrast falloff never gets brighter")
            try expectTrue(value >= 0.45, "the contrast floor is ~0.45, got \(value)")
            previous = value
        }
        // Contrast never dims the focus below the normal neighbours.
        try expectTrue(PoemFocus.opacity(distanceRows: 3, increaseContrast: true)
                       > PoemFocus.opacity(distanceRows: 3),
                       "contrast raises the floor, it does not crush the hierarchy")
    }

    // MARK: The anchor and the per-line brightness

    /// Blank lines keep the spacing but are never the focus; with nothing to
    /// read there is no anchor at all.
    static func anchorSkipsBlankLines() throws {
        try expectEqual(PoemFocus.anchorLine(centers: centers, hasWords: hasWords, anchorY: 3.6), 3)
        // Right between two lines the nearer one wins.
        try expectEqual(PoemFocus.anchorLine(centers: centers, hasWords: hasWords, anchorY: 4.0), 3)
        // The blank line at index 4 is skipped even with the anchor inside it.
        try expectEqual(PoemFocus.anchorLine(centers: centers, hasWords: hasWords, anchorY: 5.5), 5)
        try expectEqual(PoemFocus.anchorLine(centers: centers, hasWords: hasWords, anchorY: 0.1), 0)
        try expectEqual(PoemFocus.anchorLine(centers: [], hasWords: [], anchorY: 0), nil)
        try expectEqual(PoemFocus.anchorLine(centers: centers, hasWords: centers.map { _ in false },
                                             anchorY: 2), nil)
    }

    /// The hasWords inputs are derived from the real lines of a poem — never
    /// a hand-kept list: an inverted mapping would quietly turn every verse
    /// blank and switch the whole gradient off.
    static func realTextLinesAreFocusable() throws {
        let lines = ["Hope is the thing with feathers",
                     "That perches in the soul,",
                     "",
                     "And sings the tune without the words;",
                     "—"]
        let hasWords = lines.map { PoemWords.hasWords(in: $0) }
        try expectEqual(hasWords, [true, true, false, true, false],
                        "verse lines hold words, stanza breaks and dashes do not")
        let centers = (0..<lines.count).map { Double($0) + 0.5 }
        let anchor = PoemFocus.anchorLine(centers: centers, hasWords: hasWords, anchorY: 2.6)
        try expectEqual(anchor, 3, "the stanza break is skipped, the verse after it is the focus")
        let values = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                         anchorY: 1.5, unitHeight: 1)
        try expectEqual(values[1], 1, "the focus line is clear")
        try expectTrue(values[0] < 1 && values[0] > 0.5, "the verse above steps back, not away")
        try expectTrue(values[3] < 1, "a verse line is dimmable — it is no blank")
        try expectEqual(values[2], 1, "the stanza break is not dimmed — it has no ink")
        try expectEqual(values[4], 1, "a dash line is not dimmed — it has no ink")
    }

    /// The brightness is strongest at the anchor line and falls monotonically
    /// with the distance on both sides; a blind unit keeps everything clear.
    static func opacitiesFallWithDistance() throws {
        let values = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                         anchorY: 2.5, unitHeight: 1)
        try expectEqual(values.count, centers.count)
        try expectEqual(values[2], 1, "the anchor line is the brightest")
        try expectTrue(values[1] > values[0], "nearer lines are brighter")
        try expectTrue(values[3] > values[5], "nearer lines are brighter on the other side")
        try expectTrue(values[4] == 1, "a blank line is not dimmed — it has no ink")
        // Symmetric distances read the same.
        try expectEqual(values[1], values[3], "the same distance reads the same")
        // A continuous move of the anchor changes the brightness continuously:
        // a small move changes every line only a little (the slider glides,
        // it does not jump).
        let moved = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                        anchorY: 2.6, unitHeight: 1)
        for index in centers.indices {
            try expectTrue(abs(values[index] - moved[index]) < 0.1,
                           "line \(index) changes smoothly, got \(abs(values[index] - moved[index]))")
        }
        let blind = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                        anchorY: 2.5, unitHeight: 0)
        try expectTrue(blind.allSatisfy { $0 == 1 }, "no unit, no dimming")
    }

    /// Lines that hold the new words of the break keep the secondary
    /// emphasis: a long break whose words cross a line boundary does not
    /// crush the line it just completed into the old context.
    static func newWordLinesStayReadable() throws {
        var boosted = Set<Int>()
        boosted.insert(2)
        let values = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                         anchorY: 6.5, unitHeight: 1,
                                         boostedLineOpacity: PoemFocus.newWordLineOpacity,
                                         boostedLines: boosted)
        try expectTrue(values[2] >= 0.8, "the new-word line keeps its emphasis, got \(values[2])")
        try expectTrue(values[5] > values[2], "the frontier still outranks it")
        try expectTrue(values[0] < values[2], "a far line without new words stays behind")
        // Without the boost the same line falls to its distance.
        let plain = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                        anchorY: 6.5, unitHeight: 1)
        try expectTrue(plain[2] < values[2], "the boost lifts the line above its distance")
    }

    /// The boost belongs to the follow: while the reader reviews earlier
    /// lines, their chosen focus wins and the boost steps aside.
    static func boostOnlyWhileFollowing() throws {
        // The boost is applied by the caller (nil while reviewing); the core
        // honours exactly what it is given.
        let values = PoemFocus.opacities(centers: centers, hasWords: hasWords,
                                         anchorY: 0.5, unitHeight: 1,
                                         boostedLineOpacity: nil,
                                         boostedLines: [5])
        try expectEqual(values[0], 1, "reviewing the top focuses the top")
        try expectTrue(values[5] < 0.3,
                       "a boosted line far from the review stays at its distance, got \(values[5])")
    }

    /// The row unit is the smallest measured height: a wrapped line counts
    /// as it is, and an empty body has no row at all.
    static func rowUnitIsTheSmallestLine() throws {
        try expectEqual(PoemFocus.rowUnit(heights: [20, 44, 20]), 20)
        try expectEqual(PoemFocus.rowUnit(heights: []), 0)
    }

    // MARK: The reading anchor of a scroll position

    /// The scroll position decides where the focus points: the top of the
    /// poem reads at its first line with words, its end at its last one. The
    /// stanza breaks (the blank lines) are skipped at both ends, and the
    /// rows are not of one height — a wrapped line counts as it is.
    static func scrollAnchorReadsTheEnds() throws {
        let top = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                           hasWords: scrolledHasWords,
                                                           fraction: 0))
        let bottom = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                              hasWords: scrolledHasWords,
                                                              fraction: 1))
        try expectEqual(top, 30, "the leading stanza break is skipped")
        try expectEqual(bottom, 100, "the trailing blanks are skipped")
        // The middle of the poem is the middle between them.
        let middle = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                               hasWords: scrolledHasWords,
                                                               fraction: 0.5))
        try expectEqual(middle, 65)
        try expectTrue(middle > top && middle < bottom,
                       "the middle of the poem lies between its ends")
    }

    /// The focus travels with the scroll: it never jumps back and never jumps
    /// ahead of the reader.
    static func scrollAnchorTravelsContinuously() throws {
        var previous = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                                hasWords: scrolledHasWords,
                                                                fraction: 0))
        let step = 0.05
        let span = 100.0 - 30.0
        for index in 1...20 {
            let fraction = Double(index) * step
            let anchor = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                                   hasWords: scrolledHasWords,
                                                                   fraction: fraction))
            try expectTrue(anchor >= previous - 1e-9,
                           "the focus never goes back at \(fraction)")
            try expectTrue(anchor - previous <= span * step + 1e-9,
                           "the focus moves with the scroll at \(fraction)")
            previous = anchor
        }
        try expectEqual(previous, 100, "the travel ends at the last line with words")
    }

    /// The elastic overscroll of the scroller carries the position past the
    /// ends of the poem: the focus clamps there instead of leaving the poem.
    static func scrollAnchorClamps() throws {
        let above = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                              hasWords: scrolledHasWords,
                                                              fraction: -0.25))
        let below = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                              hasWords: scrolledHasWords,
                                                              fraction: 1.25))
        try expectEqual(above, 30, "an overscroll above the poem stays at its first line")
        try expectEqual(below, 100, "an overscroll below the poem stays at its last line")
    }

    /// A body without words, a body with one line and a body that does not
    /// scroll at all stay safe: the first two never break, the third reads at
    /// the beginning of the poem.
    static func scrollAnchorStaysSafe() throws {
        try expectNil(PoemFocus.scrollAnchorY(centers: [], hasWords: [], fraction: 0.5))
        try expectNil(PoemFocus.scrollAnchorY(centers: [1, 2], hasWords: [false, false],
                                               fraction: 0.5))
        let single = try expectNotNil(PoemFocus.scrollAnchorY(centers: [7], hasWords: [true],
                                                              fraction: 0.5))
        try expectEqual(single, 7, "a body of one line reads at that line")
        // A body that does not scroll reads at its first line with words.
        let short = try expectNotNil(PoemFocus.scrollAnchorY(centers: scrolledCenters,
                                                             hasWords: scrolledHasWords,
                                                             fraction: 0))
        try expectEqual(short, 30)
    }

    // MARK: The focus mark of a session


    /// While the poem grows the frontier line is marked, and so are the lines
    /// that received the new words of this break.
    static func focusMarkOfASession() throws {
        // Four words crossing the line boundary: three on the first line, one
        // on the second. Both lines hold new words; the frontier is the
        // second one.
        let crossing = revealing(makePoem(lines: ["one two three", "four five six"]),
                                 mini: false, revealedBefore: 0)
        let mark = crossing.focusMark
        try expectEqual(mark.frontierLine, 1)
        try expectEqual(mark.newWordLines, [0, 1])
        try expectEqual(mark.secondaryLines, [0], "the just completed line keeps the emphasis")

        // One new word on the frontier line alone: nothing secondary.
        let sameLine = revealing(makePoem(lines: ["one two three", "four five six"]),
                                 revealedBefore: 1)
        try expectEqual(sameLine.focusMark.frontierLine, 0)
        try expectEqual(sameLine.focusMark.newWordLines, [0])
        try expectTrue(sameLine.focusMark.secondaryLines.isEmpty)

        // The words of a stanza break keep the blank line out of the mark.
        let stanza = revealing(makePoem(lines: ["one two", "", "three four five six seven"]),
                               mini: false, revealedBefore: 0)
        try expectEqual(stanza.focusMark.frontierLine, 2)
        try expectEqual(stanza.focusMark.newWordLines, [0, 2])
    }

    /// The complete poem has no frontier: its focus follows the travel.
    static func focusMarkOfTheCompletePoem() throws {
        let complete = PoemBreakSession.complete(poem: makePoem(lines: ["one two", "three four"]),
                                                 mini: false, startedAt: 0, durationMillis: 5_000)
        try expectEqual(complete.focusMark.frontierLine, -1)
        try expectTrue(complete.focusMark.newWordLines.isEmpty)
        // An empty poem has nothing to mark.
        let empty = revealing(makePoem(lines: ["", "  "]), revealedBefore: 0)
        try expectEqual(empty.focusMark.frontierLine, -1)
        try expectTrue(empty.focusMark.newWordLines.isEmpty)
    }

    /// The focus mark reads only the captured session: the reveal itself
    /// (before/after, kind, mode, token) stays exactly what the break
    /// committed — no scroll, review or focus ever moves it.
    static func focusNeverTouchesTheReveal() throws {
        let poem = makePoem(lines: ["one two three", "four five six"])
        let session = revealing(poem, mini: false, revealedBefore: 1)
        _ = session.focusMark
        _ = PoemFocus.opacities(centers: [0.5, 1.5], hasWords: [true, true],
                                anchorY: 0.5, unitHeight: 1)
        _ = PoemFocus.scrollAnchorY(centers: [0.5, 1.5], hasWords: [true, true], fraction: 1)
        try expectEqual(session.revealedBefore, 1)
        try expectEqual(session.revealedAfter, 5)
        try expectEqual(session.kind, .advancing)
        try expectEqual(session.mode, .revealing)
        try expectEqual(session.preview.lines, ["one two three", "four five"])
    }
}
