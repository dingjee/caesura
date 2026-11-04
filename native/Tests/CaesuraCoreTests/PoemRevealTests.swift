import Foundation
import CaesuraCore

enum PoemRevealTests {
    static func registerAll() {
        TestRunner.register("poem reveal: abbreviations and joined words stay one word", tokenizerJoinedWords)
        TestRunner.register("poem reveal: standalone punctuation and blank lines are no words", tokenizerStandalonePunctuation)
        TestRunner.register("poem reveal: an empty poem has no words", tokenizerEmptyPoem)
        TestRunner.register("poem reveal: a mini reveals one word, a long break four", revealBudgets)
        TestRunner.register("poem reveal: the reveal stops at the end of the poem", revealStopsAtTheEnd)
        TestRunner.register("poem reveal: the revealed position is clamped into the poem", revealClampsPosition)
        TestRunner.register("poem reveal: the preview keeps the revealed context and cuts at the frontier", previewWindow)
        TestRunner.register("poem reveal: the preview never shows a word that is not revealed", previewShowsOnlyRevealedWords)
        TestRunner.register("poem reveal: the soft edge covers the last revealed words", previewSoftEdgeCoversTheRevealedTail)
        TestRunner.register("poem reveal: the soft edge band never crosses a line boundary", previewBandStopsAtTheLineEnd)
        TestRunner.register("poem reveal: the line before the frontier stays complete", previewKeepsCompleteLines)
        TestRunner.register("poem reveal: the revealed context survives across blank lines", previewKeepsTheWholeRevealedContext)
        TestRunner.register("poem reveal: an empty poem previews nothing", previewEmptyPoem)
        TestRunner.register("poem reveal: the complete poem is shown without a soft edge", previewCompletePoem)
        TestRunner.register("poem reveal: the soft edge is one slanted band", softEdgeAxis)
        TestRunner.register("poem reveal: the soft edge keeps the newest word readable", softEdgeAlphaProfile)
    }

    // MARK: Helpers

    static func makePoem(id: String = "p1", lines: [String]) -> Poem {
        Poem(id: id, title: "Test Poem", author: "Test Author", lines: lines,
             excerpt: Array(lines.prefix(2)), seasons: [], months: [],
             authorBorn: nil, authorDied: nil, source: "test")
    }

    /// The poem of the preview cases: eleven words on two lines.
    static let twoLines = ["Hope is the thing with feathers", "That perches in the soul"]

    /// A break that reveals the poem word by word.
    static func revealing(_ poem: Poem, mini: Bool, revealedBefore: Int) -> PoemBreakSession {
        PoemBreakSession.revealing(poem: poem, mini: mini, startedAt: 1_000,
                                   durationMillis: mini ? 3_000 : 5_000,
                                   revealedBefore: revealedBefore)
    }

    // MARK: Tokenizer

    static func tokenizerJoinedWords() throws {
        let words = PoemWords.words(in: ["Mr. Smith went to U.S.A. yesterday."])
        try expectEqual(words.count, 6)
        try expectEqual(words[0].start, 0)
        try expectEqual(words[0].end, 2, "the word itself is 'Mr'")
        try expectEqual(words[0].displayEnd, 3, "the dot belongs to the word but is no word")
        try expectEqual(words[4].start, 18)
        try expectEqual(words[4].end, 23, "'U.S.A' is one word")
        try expectEqual(words[4].displayEnd, 24, "the last dot belongs to the word")

        let joined = PoemWords.words(in: ["well-known don't 3.5"])
        try expectEqual(joined.count, 3)
        try expectEqual(joined[0].end, 10, "'well-known' is one word")
        try expectEqual(joined[1].start, 11)
        try expectEqual(joined[1].end, 16, "'don't' is one word")
        try expectEqual(joined[2].start, 17)
        try expectEqual(joined[2].end, 20, "'3.5' is one word")
        try expectEqual(joined[2].displayEnd, 20, "a digit with a dot has no trailing punctuation")
    }

    static func tokenizerStandalonePunctuation() throws {
        let words = PoemWords.words(in: ["—", "", "   ", "\"Hello,\" she said."])
        try expectEqual(words.count, 3, "an em dash and blank lines are no words")
        try expectEqual(words[0].lineIndex, 3, "the words know their line")
        try expectEqual(words[0].start, 1, "the opening quote stands alone")
        try expectEqual(words[0].end, 6)
        try expectEqual(words[0].displayEnd, 8, "the comma and the closing quote belong to the word")
        try expectEqual(words[1].start, 9)
        try expectEqual(words[2].end, 17)
        try expectEqual(words[2].displayEnd, 18, "the final dot belongs to the word")
    }

    static func tokenizerEmptyPoem() throws {
        try expectEqual(PoemWords.count(in: []), 0)
        try expectEqual(PoemWords.count(in: ["", "   "]), 0)
        try expectEqual(PoemWords.words(in: []).count, 0)
    }

    // MARK: Reveal

    static func revealBudgets() throws {
        let poem = makePoem(lines: ["one two three four five six seven eight nine ten"])
        let mini = revealing(poem, mini: true, revealedBefore: 0)
        try expectEqual(mini.revealedBefore, 0)
        try expectEqual(mini.revealedAfter, 1, "a mini break reveals one word")
        try expectEqual(mini.totalWords, 10)
        try expectEqual(mini.kind, .advancing)
        try expectEqual(mini.mode, .revealing)
        try expectEqual(mini.startedAt, 1_000)
        try expectEqual(mini.durationMillis, 3_000)
        try expectTrue(mini.mini)

        let long = revealing(poem, mini: false, revealedBefore: 0)
        try expectEqual(long.revealedAfter, 4, "a long break reveals four words")
        try expectFalse(long.mini)
        try expectEqual(long.durationMillis, 5_000)
    }

    static func revealStopsAtTheEnd() throws {
        let poem = makePoem(lines: ["one two three"])
        let long = revealing(poem, mini: false, revealedBefore: 0)
        try expectEqual(long.revealedAfter, 3, "the reveal stops at the end of the poem")
        try expectEqual(long.kind, .unlocking, "the break that completes the poem unlocks it")
        try expectEqual(long.mode, .full, "the complete poem is shown in full")
        let again = revealing(poem, mini: true, revealedBefore: 3)
        try expectEqual(again.revealedBefore, 3)
        try expectEqual(again.revealedAfter, 3, "the poem never wraps around")
        try expectEqual(again.kind, .repeating, "a complete poem is repeated, not advanced")
        try expectEqual(again.mode, .full)
    }

    static func revealClampsPosition() throws {
        let poem = makePoem(lines: ["one two three"])
        let negative = revealing(poem, mini: true, revealedBefore: -7)
        try expectEqual(negative.revealedBefore, 0)
        try expectEqual(negative.revealedAfter, 1)
        let huge = revealing(poem, mini: true, revealedBefore: 99_999)
        try expectEqual(huge.revealedBefore, 3)
        try expectEqual(huge.revealedAfter, 3)
    }

    // MARK: Preview

    static func previewWindow() throws {
        let poem = makePoem(lines: twoLines)
        let preview = revealing(poem, mini: true, revealedBefore: 0).preview
        try expectEqual(preview.lines.count, 1, "the first line alone holds the first words")
        try expectEqual(preview.lines[0], "Hope")
        try expectEqual(preview.softEdgeLineIndex, 0)
        try expectEqual(preview.softEdgeOffset, 0, "the only word belongs to the soft edge")
        try expectEqual(preview.textEndOffset, 4, "the text ends after 'Hope'")

        let long = revealing(poem, mini: false, revealedBefore: 0).preview
        try expectEqual(long.lines.count, 1)
        try expectEqual(long.lines[0], "Hope is the thing")
        try expectEqual(long.softEdgeOffset, 5, "the soft edge starts at 'is'")
        try expectEqual(long.textEndOffset, 17, "the text ends after 'thing'")
    }

    /// The window shows the words that are revealed — and nothing else. A word
    /// that is not revealed yet never shows up, not even as a hint.
    static func previewShowsOnlyRevealedWords() throws {
        let poem = makePoem(lines: twoLines)
        // The first Mini break: the first word and its punctuation.
        let first = revealing(poem, mini: true, revealedBefore: 0).preview
        try expectEqual(first.lines, ["Hope"], "only the revealed word is shown")
        try expectEqual(first.textEndOffset, 4, "the text ends after 'Hope'")

        // The first Long break: four words.
        let long = revealing(poem, mini: false, revealedBefore: 0).preview
        try expectEqual(long.lines, ["Hope is the thing"], "the four revealed words, nothing more")
        try expectEqual(long.textEndOffset, 17)

        // The next Mini break reveals one word more.
        let second = revealing(poem, mini: true, revealedBefore: 1).preview
        try expectEqual(second.lines, ["Hope is"], "the second word joins the first one")
        try expectEqual(second.textEndOffset, 7)
        try expectEqual(second.softEdgeOffset, 0, "both words belong to the soft edge")

        // The words after the frontier stay invisible.
        for revealed in 0..<10 {
            let preview = revealing(poem, mini: true, revealedBefore: revealed).preview
            let words = PoemWords.words(in: preview.lines)
            let revealedWords = PoemWords.words(in: poem.lines).prefix(revealed + 1)
            try expectEqual(words.count, revealedWords.count,
                            "exactly the revealed words are shown (revealed \(revealed))")
            for (shown, expected) in zip(words, revealedWords) {
                try expectEqual(shown.end - shown.start, expected.end - expected.start)
            }
        }
    }

    /// The soft edge covers the end of the revealed text: the word that the
    /// break revealed and the words before it.
    static func previewSoftEdgeCoversTheRevealedTail() throws {
        let poem = makePoem(lines: ["one two three four five six seven eight"])
        // Six revealed words: the soft edge covers the last three of them.
        let preview = revealing(poem, mini: true, revealedBefore: 5).preview
        try expectEqual(preview.lines, ["one two three four five six"])
        try expectEqual(preview.textEndOffset, 27, "the text ends after 'six'")
        try expectEqual(preview.softEdgeOffset, 14, "the soft edge starts at 'four'")
    }

    static func previewBandStopsAtTheLineEnd() throws {
        // The soft edge never crosses the line break of the poem.
        let poem = makePoem(lines: ["Hope is the", "thing with feathers"])
        let preview = revealing(poem, mini: false, revealedBefore: 0).preview
        // Four revealed words: 'Hope is the' on the first line, 'thing' on the second.
        try expectEqual(preview.lines, ["Hope is the", "thing"])
        try expectEqual(preview.softEdgeLineIndex, 1)
        try expectEqual(preview.softEdgeOffset, 0, "the soft edge starts at the first word of the line")
        try expectEqual(preview.textEndOffset, 5, "the text ends after 'thing'")
    }

    static func previewKeepsCompleteLines() throws {
        let poem = makePoem(lines: twoLines)
        // Seven revealed words: the frontier sits on the second line.
        let preview = revealing(poem, mini: true, revealedBefore: 6).preview
        try expectEqual(preview.lines.count, 2, "the revealed context starts at the first line")
        try expectEqual(preview.lines[0], "Hope is the thing with feathers",
                        "the line before the frontier stays complete")
        try expectEqual(preview.lines[1], "That")
        try expectEqual(preview.softEdgeLineIndex, 1, "the soft edge sits on the frontier line")
        try expectEqual(preview.softEdgeOffset, 0, "the soft edge starts at the first word of the line")
        try expectEqual(preview.textEndOffset, 4, "the text ends after 'That'")

        // Nine revealed words: three of them share the soft edge.
        let deeper = revealing(poem, mini: true, revealedBefore: 8).preview
        try expectEqual(deeper.lines[1], "That perches in")
        try expectEqual(deeper.softEdgeOffset, 0, "the soft edge starts at 'That'")
        try expectEqual(deeper.textEndOffset, 15, "the text ends after 'in'")
    }

    /// The revealed context stays readable from the beginning: earlier lines
    /// and the blank lines between the stanzas survive, and nothing beyond the
    /// frontier shows up.
    static func previewKeepsTheWholeRevealedContext() throws {
        let poem = makePoem(lines: ["one two three four",
                                    "",
                                    "five six seven eight nine ten",
                                    "eleven twelve"])
        // Ten revealed words: the frontier sits on the third line, after 'ten'.
        let preview = revealing(poem, mini: true, revealedBefore: 9).preview
        try expectEqual(preview.lines.count, 3, "the first stanza and the blank line stay")
        try expectEqual(preview.lines[0], "one two three four",
                        "the first line stays complete")
        try expectEqual(preview.lines[1], "", "the blank line between the stanzas stays")
        try expectEqual(preview.lines[2], "five six seven eight nine ten")
        try expectEqual(preview.softEdgeLineIndex, 2, "the soft edge sits on the frontier line")
        try expectEqual(preview.softEdgeOffset, 15, "the soft edge starts at 'eight'")
        try expectEqual(preview.textEndOffset, 29, "the text ends after 'ten'")
        // The fourth line does not show up.
        try expectTrue(!preview.lines.contains("eleven"),
                       "a word that is not revealed yet never shows up")
        // A deeper frontier on the last line keeps the whole context. (With
        // one more word the poem would be complete and shown without a soft
        // edge — that is the unlocking break, not a frontier.)
        let deeper = revealing(poem, mini: true, revealedBefore: 10).preview
        try expectEqual(deeper.lines.count, 4)
        try expectEqual(deeper.lines[3], "eleven")
        try expectEqual(deeper.softEdgeLineIndex, 3)
    }

    /// A poem without words has nothing to reveal: it is shown as it is.
    static func previewEmptyPoem() throws {
        let poem = makePoem(lines: ["", "   "])
        let captured = revealing(poem, mini: true, revealedBefore: 0)
        try expectEqual(captured.totalWords, 0)
        try expectEqual(captured.revealedAfter, 0)
        let preview = captured.preview
        try expectEqual(PoemWords.count(in: preview.lines), 0, "an empty poem shows no words")
        try expectEqual(preview.softEdgeOffset, 0)
        try expectEqual(preview.textEndOffset, 0)
    }

    /// The complete poem is shown line by line, without a soft edge.
    static func previewCompletePoem() throws {
        let poem = makePoem(lines: twoLines)
        let complete = PoemBreakSession.complete(poem: poem, mini: true, startedAt: 1_000,
                                                 durationMillis: 3_000)
        let preview = complete.preview
        try expectEqual(preview.lines, twoLines, "every line of the poem is shown")
        try expectEqual(preview.softEdgeLineIndex, -1, "the complete poem carries no soft edge")
        try expectEqual(preview.softEdgeOffset, 0)
        try expectEqual(preview.textEndOffset, 0)
    }

    // MARK: Soft edge

    static func softEdgeAxis() throws {
        let flat = PoemRevealSoftEdge(startX: 10, width: 100, tilt: 0).axis()
        try expectEqual(flat.startX, 10)
        try expectEqual(flat.startY, 0)
        try expectEqual(flat.endY, 0, "a tilt of zero keeps the fade horizontal")
        try expectTrue(flat.endX > flat.startX, "the fade runs to the right")

        let slanted = PoemRevealSoftEdge(startX: 10, width: 100, tilt: 1).axis()
        try expectTrue(slanted.endY > 0, "a positive tilt slants the fade")
        try expectTrue(slanted.endX - slanted.startX < flat.endX - flat.startX,
                       "a slanted fade covers less of the line")

        let shifted = PoemRevealSoftEdge(startX: 60, width: 100, tilt: 1).axis()
        try expectEqual(shifted.endX - shifted.startX, slanted.endX - slanted.startX,
                        "the shape does not depend on the position")
        try expectEqual(shifted.endY, slanted.endY)
    }

    /// The transparency of the soft edge: the band stays readable and only its
    /// very end is really transparent — the newest word of the break has to be
    /// recognizable at a glance.
    static func softEdgeAlphaProfile() throws {
        let profile = PoemRevealSoftEdge.alphaProfile()
        try expectEqual(profile.first?.position, 0)
        try expectEqual(profile.first?.alpha, 1.0, "the text in front of the edge stays clear")
        try expectEqual(profile.last?.position, 1.0)
        try expectTrue((profile.last?.alpha ?? 1) < 0.2, "the end of the edge is transparent")
        let atSixty = profile.first { $0.position >= 0.6 }?.alpha ?? 0
        try expectTrue(atSixty > 0.7, "the newest word has to stay readable, got \(atSixty)")
        // The main glyphs of the newest word keep about three quarters of
        // their ink; only a short decorative tail goes really transparent.
        for stop in profile where stop.position <= 0.85 {
            try expectTrue(stop.alpha >= 0.75,
                           "the main glyphs stay readable, got \(stop.alpha) at \(stop.position)")
        }
        var previous = 1.0
        for stop in profile {
            try expectTrue(stop.alpha <= previous, "the profile never gets brighter")
            previous = stop.alpha
        }
    }
}
