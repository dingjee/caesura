import Foundation

/// One word of a poem, with its position inside its line (character offsets).
///
/// The offsets are needed because the break window cuts the original line: it
/// has to know where the revealed text ends and where the next word starts.
public struct PoemWord: Equatable {
    /// Index of the line the word belongs to.
    public let lineIndex: Int
    /// Character offset of the word itself inside its line.
    public let start: Int
    /// Character offset (exclusive) of the word itself.
    public let end: Int
    /// Character offset (exclusive) of the word including its trailing punctuation.
    public let displayEnd: Int

    public init(lineIndex: Int, start: Int, end: Int, displayEnd: Int) {
        self.lineIndex = lineIndex
        self.start = start
        self.end = end
        self.displayEnd = displayEnd
    }
}

/// Splits poem lines into words without losing the original text.
///
/// The tokenizer is deliberately small: a word starts at a letter or a digit
/// and an apostrophe, a hyphen or a dot glues two word characters together
/// ("don't", "well-known", "U.S.A." are one word each). Punctuation that clings
/// to a word belongs to its display range but never counts as a word, so the
/// break window can cut a line without dropping the punctuation of the
/// revealed part. Standalone punctuation (an em dash, an opening quote) and
/// blank lines are no words at all.
public enum PoemWords {
    /// All words of the poem, in reading order.
    public static func words(in lines: [String]) -> [PoemWord] {
        var result: [PoemWord] = []
        for (lineIndex, line) in lines.enumerated() {
            result.append(contentsOf: words(in: line, lineIndex: lineIndex))
        }
        return result
    }

    /// True when the line holds at least one word (blank lines and lines of
    /// standalone punctuation hold none: they keep the spacing of the
    /// stanzas but are never a reading focus).
    public static func hasWords(in line: String) -> Bool {
        line.contains { $0.isLetter || $0.isNumber }
    }

    /// The number of words of the poem.
    public static func count(in lines: [String]) -> Int {
        words(in: lines).count
    }

    static func words(in line: String, lineIndex: Int) -> [PoemWord] {
        let characters = Array(line)
        var result: [PoemWord] = []
        var index = 0
        while index < characters.count {
            guard isWordStart(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            var cursor = index + 1
            var end = cursor
            while cursor < characters.count {
                let character = characters[cursor]
                if isWordStart(character) {
                    cursor += 1
                    end = cursor
                } else if isJoiner(character), cursor + 1 < characters.count,
                          isWordStart(characters[cursor + 1]) {
                    // "don't", "well-known" and "U.S.A." stay one word.
                    cursor += 2
                    end = cursor
                } else {
                    break
                }
            }
            var displayEnd = end
            while displayEnd < characters.count, isTrailingPunctuation(characters[displayEnd]) {
                displayEnd += 1
            }
            result.append(PoemWord(lineIndex: lineIndex, start: start, end: end, displayEnd: displayEnd))
            index = displayEnd
        }
        return result
    }

    /// A word starts at a letter or a digit.
    private static func isWordStart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Characters that join two word characters into a single word.
    private static func isJoiner(_ character: Character) -> Bool {
        character == "." || character == "-" || character == "'" || character == "\u{2019}"
    }

    /// Punctuation that hangs directly behind a word and belongs to its
    /// display range. Opening punctuation (a quote, a bracket) is not part of
    /// it: it belongs to the word in front of it.
    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}\"'%\u{2026}\u{2019}\u{201D}\u{2014}\u{2013}".contains(character)
    }
}

/// What the break window shows for one session.
///
/// A revealing break shows the revealed text from its beginning through the
/// frontier, cut at the frontier; a break that shows the complete poem shows
/// every line of it and carries no soft edge (`softEdgeLineIndex` is then
/// `-1`).
public struct PoemRevealPreview: Equatable {
    /// The visible lines of the poem.
    public let lines: [String]
    /// Index inside `lines` of the line carrying the soft edge (`-1` when the
    /// whole poem is shown).
    public let softEdgeLineIndex: Int
    /// Character offset in that line where the soft edge starts (the first
    /// character of the first word that belongs to the edge).
    public let softEdgeOffset: Int
    /// Character offset in that line where the visible text ends (the end of
    /// the last revealed word).
    public let textEndOffset: Int

    public init(lines: [String], softEdgeLineIndex: Int, softEdgeOffset: Int, textEndOffset: Int) {
        self.lines = lines
        self.softEdgeLineIndex = softEdgeLineIndex
        self.softEdgeOffset = softEdgeOffset
        self.textEndOffset = textEndOffset
    }
}

/// The progressive reveal of the poem of a break.
///
/// A Mini break reveals one new word, a Long break four; the poem grows from
/// its beginning over the breaks and stops at its end. The window keeps the
/// whole revealed text readable — every line from the first one through the
/// frontier line — and the last words share one soft edge. When the poem is
/// complete, the break shows the whole poem instead.
public enum PoemReveal {
    /// Words a Mini break reveals.
    public static let miniBudget: Int = 1
    /// Words a Long break reveals.
    public static let longBudget: Int = 4
    /// Words sharing the soft edge at the end of the revealed text.
    public static let softEdgeWords: Int = 3

    /// The words one break reveals.
    public static func budget(mini: Bool) -> Int {
        mini ? miniBudget : longBudget
    }

    /// The reveal interval of one break: the words revealed before it and the
    /// words revealed after it. The poem caps at its end and never wraps.
    public static func interval(totalWords: Int, mini: Bool,
                                revealedBefore: Int) -> (before: Int, after: Int) {
        let total = max(totalWords, 0)
        let before = min(max(revealedBefore, 0), total)
        let after = min(before + budget(mini: mini), total)
        return (before, after)
    }

    /// What a break does with the poem.
    ///
    /// The break that completes the poem for the first time is not a
    /// repetition: it only pushes the poem to its end.
    public static func kind(revealedBefore: Int, revealedAfter: Int,
                            totalWords: Int) -> PoemBreakSession.Kind {
        if revealedBefore < totalWords, revealedAfter >= totalWords { return .unlocking }
        if revealedBefore >= totalWords { return .repeating }
        return .advancing
    }

    /// What the break window draws: the frontier window while the poem grows,
    /// the whole poem once it is complete.
    public static func mode(revealedAfter: Int, totalWords: Int) -> PoemBreakSession.Mode {
        revealedAfter >= totalWords ? .full : .revealing
    }

    /// Cuts the poem at the frontier of the session.
    ///
    /// The visible text is the revealed context: every line from the first one
    /// through the frontier line, cut after the last revealed word. A word
    /// that is not revealed yet never shows up, and the earlier lines stay
    /// readable, so the poem does not jump when a new break reveals its words.
    ///
    /// The soft edge covers the last words of the revealed text — the word that
    /// this break revealed and the ones before it. It never crosses a line
    /// boundary: the line breaks of the poem stay where they are.
    public static func preview(for session: PoemBreakSession) -> PoemRevealPreview {
        if session.mode == .full {
            // The poem is complete: every line is shown, without a soft edge.
            return PoemRevealPreview(lines: session.lines, softEdgeLineIndex: -1,
                                     softEdgeOffset: 0, textEndOffset: 0)
        }
        let words = PoemWords.words(in: session.lines)
        let total = words.count
        let frontier = min(max(session.revealedAfter, 0), total)
        guard frontier > 0, !words.isEmpty else {
            // Nothing is revealed yet (or the poem has no words at all).
            return PoemRevealPreview(lines: [], softEdgeLineIndex: 0, softEdgeOffset: 0, textEndOffset: 0)
        }
        let lastWord = words[frontier - 1]
        let frontierLine = lastWord.lineIndex
        // The visible text ends with the last revealed word (with its
        // punctuation); the words after it are not revealed yet.
        let textEndOffset = lastWord.displayEnd
        // The soft edge starts at the first of the last words that is still on
        // the frontier line.
        var bandStart = max(0, frontier - softEdgeWords)
        while bandStart < frontier, words[bandStart].lineIndex != frontierLine {
            bandStart += 1
        }
        let softEdgeOffset = words[bandStart].start
        // The whole revealed context stays readable: the lines before the
        // frontier are complete, blank lines included.
        var visible = Array(session.lines[0..<frontierLine])
        visible.append(String(session.lines[frontierLine].prefix(textEndOffset)))
        return PoemRevealPreview(lines: visible,
                                 softEdgeLineIndex: frontierLine,
                                 softEdgeOffset: softEdgeOffset,
                                 textEndOffset: textEndOffset)
    }
}

/// The geometry of the ONE shared diagonal soft edge (pure math, no UI types).
///
/// The edge is a diagonal band at the end of the revealed text: the words in
/// front of it stay clear, the band itself fades out behind it. The whole band
/// is one gradient, not one gradient per word.
public struct PoemRevealSoftEdge: Equatable {
    /// X of the fade inside the rendered line, in points.
    public let startX: Double
    /// Width of the fade, in points.
    public let width: Double
    /// Slope of the fade across the line height (dimensionless).
    public let tilt: Double

    public init(startX: Double, width: Double, tilt: Double) {
        self.startX = startX
        self.width = width
        self.tilt = tilt
    }

    /// The axis of the gradient in the coordinate space of the line: the fade is
    /// opaque at `start` and transparent at `end`.
    public func axis() -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let dx = width / (1 + tilt * tilt)
        return (startX, 0, startX + dx, tilt * dx)
    }

    /// The transparency of the fade, from its start (0) to its end (1).
    ///
    /// The fade is gentle: the band stays readable and only its very end is
    /// really transparent. The newest word of the break has to be
    /// recognizable at a glance — its main glyphs keep at least about three
    /// quarters of their ink — and the deep end of the edge may only be a
    /// short distance.
    public static func alphaProfile() -> [(position: Double, alpha: Double)] {
        // The band stays clear for a long time, holds ~0.75 through the main
        // glyphs of the newest word and drops quickly at its very end.
        [(0, 1.0), (0.4, 0.97), (0.6, 0.92), (0.75, 0.86), (0.85, 0.75),
         (0.93, 0.4), (1.0, 0.06)]
    }
}
