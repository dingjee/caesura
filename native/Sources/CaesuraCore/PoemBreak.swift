import Foundation

/// The poem of a break, captured when the break starts.
///
/// The session is immutable: a changed setting or a new day never changes
/// what the running break shows. The whole poem is captured, because the
/// break may show any part of it.
///
/// The session carries two different things and they must not be mixed up:
///
/// - `kind` says what the break **does** with the poem. It decides what a
///   committed break counts.
/// - `mode` says what the break window **draws**. It only decides how the poem
///   looks.
///
/// The break that completes the poem for the first time shows the whole poem
/// (`mode == .full`) but it is not a repetition (`kind == .unlocking`).
public struct PoemBreakSession: Equatable {
    /// What the break does with the poem of the rotation.
    public enum Kind: String, Equatable {
        /// The break reveals the next words of the poem.
        case advancing
        /// The break reveals the last words: the poem is complete for the
        /// first time.
        case unlocking
        /// The poem is complete already: the break shows it again.
        case repeating
    }

    /// What the break window draws.
    public enum Mode: String, Equatable {
        /// The lines around the frontier, with the soft edge at their end.
        case revealing
        /// The whole poem, line by line, without a soft edge.
        case full
    }

    /// The id of the poem, used to detect a changed rotation.
    public let poemId: String
    public let title: String
    public let author: String
    /// The whole poem, line by line.
    public let lines: [String]
    /// True for a Mini break, false for a Long break.
    public let mini: Bool
    /// Start of the break in epoch milliseconds.
    public let startedAt: Int64
    /// Duration of the break in milliseconds.
    public let durationMillis: Int64
    /// What the break does with the poem.
    public let kind: Kind
    /// What the break window draws.
    public let mode: Mode
    /// Words of the poem revealed before this break.
    public let revealedBefore: Int
    /// Words of the poem revealed after this break.
    public let revealedAfter: Int
    /// Words of the whole poem.
    public let totalWords: Int
    /// How often the complete poem was repeated when the break started.
    public let extraRepeatsAtStart: Int
    /// How often the complete poem may be repeated in total (the captured
    /// value of the preference).
    public let extraRepeatsLimit: Int
    /// The token of the session: it makes the commit of the break idempotent.
    public let token: Int64

    public init(poemId: String, title: String, author: String, lines: [String],
                mini: Bool, startedAt: Int64, durationMillis: Int64,
                kind: Kind, mode: Mode,
                revealedBefore: Int, revealedAfter: Int, totalWords: Int,
                extraRepeatsAtStart: Int, extraRepeatsLimit: Int, token: Int64) {
        self.poemId = poemId
        self.title = title
        self.author = author
        self.lines = lines
        self.mini = mini
        self.startedAt = startedAt
        self.durationMillis = durationMillis
        self.kind = kind
        self.mode = mode
        self.revealedBefore = revealedBefore
        self.revealedAfter = revealedAfter
        self.totalWords = totalWords
        self.extraRepeatsAtStart = extraRepeatsAtStart
        self.extraRepeatsLimit = extraRepeatsLimit
        self.token = token
    }

    /// What the window shows of the poem.
    public var preview: PoemRevealPreview {
        PoemReveal.preview(for: self)
    }

    /// A break that reveals the poem word by word.
    public static func revealing(poem: Poem, mini: Bool, startedAt: Int64,
                                 durationMillis: Int64, revealedBefore: Int,
                                 token: Int64 = 0) -> PoemBreakSession {
        let total = PoemWords.count(in: poem.lines)
        let interval = PoemReveal.interval(totalWords: total, mini: mini,
                                           revealedBefore: revealedBefore)
        return PoemBreakSession(poemId: poem.id, title: poem.title, author: poem.author,
                                lines: poem.lines, mini: mini, startedAt: startedAt,
                                durationMillis: durationMillis,
                                kind: PoemReveal.kind(revealedBefore: interval.before,
                                                      revealedAfter: interval.after,
                                                      totalWords: total),
                                mode: PoemReveal.mode(revealedAfter: interval.after,
                                                     totalWords: total),
                                revealedBefore: interval.before, revealedAfter: interval.after,
                                totalWords: total, extraRepeatsAtStart: 0,
                                extraRepeatsLimit: 0, token: token)
    }

    /// A break that shows the complete poem.
    public static func complete(poem: Poem, mini: Bool, startedAt: Int64,
                                durationMillis: Int64, token: Int64 = 0) -> PoemBreakSession {
        let total = PoemWords.count(in: poem.lines)
        return PoemBreakSession(poemId: poem.id, title: poem.title, author: poem.author,
                                lines: poem.lines, mini: mini, startedAt: startedAt,
                                durationMillis: durationMillis, kind: .repeating, mode: .full,
                                revealedBefore: total, revealedAfter: total, totalWords: total,
                                extraRepeatsAtStart: 0, extraRepeatsLimit: 0, token: token)
    }
}

/// The plain content of a break: its title and its text.
public struct BreakParts: Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// The parts of a break, as the CLI can name them.
///
/// The CLI names the parts of a break it wants to change; the parts it does
/// not name stay as they are (legacy: `val || defaultNextIdea[index]`).
public enum PoemBreakParts {
    /// The title and the text of a break the CLI named.
    public static func resolve(title: String?, text: String?,
                               defaultTitle: String, defaultText: String) -> BreakParts {
        let namedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let namedText = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return BreakParts(title: namedTitle.isEmpty ? defaultTitle : title!,
                          text: namedText.isEmpty ? defaultText : text!)
    }

    /// True when the CLI named at least one part of the break.
    public static func hasCustomPart(title: String?, text: String?) -> Bool {
        let namedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let namedText = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !namedTitle.isEmpty || !namedText.isEmpty
    }
}

/// The time envelope of the poem in the break window.
public struct PoemTimeline: Equatable {
    public let fadeInMillis: Int64
    public let holdMillis: Int64
    public let fadeOutMillis: Int64

    public init(fadeInMillis: Int64, holdMillis: Int64, fadeOutMillis: Int64) {
        self.fadeInMillis = fadeInMillis
        self.holdMillis = holdMillis
        self.fadeOutMillis = fadeOutMillis
    }

    public var totalMillis: Int64 { fadeInMillis + holdMillis + fadeOutMillis }

    /// The envelope of a break: a Mini break shows the poem for about three
    /// seconds, a Long break for about five.
    public static func standard(mini: Bool) -> PoemTimeline {
        mini ? PoemTimeline(fadeInMillis: 500, holdMillis: 1500, fadeOutMillis: 1000)
             : PoemTimeline(fadeInMillis: 500, holdMillis: 3500, fadeOutMillis: 1000)
    }

    /// The envelope shortened to a very short break: every phase keeps its
    /// ratio and the envelope never grows longer than the break itself.
    public static func scaled(mini: Bool, toDuration durationMillis: Int64) -> PoemTimeline {
        let standard = standard(mini: mini)
        guard durationMillis > 0 else {
            // An illegal duration shows nothing at all.
            return PoemTimeline(fadeInMillis: 0, holdMillis: 0, fadeOutMillis: 0)
        }
        guard durationMillis < standard.totalMillis else { return standard }
        let factor = Double(durationMillis) / Double(standard.totalMillis)
        var fadeIn = Int64((Double(standard.fadeInMillis) * factor).rounded())
        var hold = Int64((Double(standard.holdMillis) * factor).rounded())
        var fadeOut = Int64((Double(standard.fadeOutMillis) * factor).rounded())
        // Rounding may overshoot the break by a millisecond; the poem may not
        // stay visible longer than the break lasts.
        var total = fadeIn + hold + fadeOut
        if total > durationMillis {
            let excess = min(fadeOut, total - durationMillis)
            fadeOut -= excess
            total -= excess
        }
        if total > durationMillis {
            let excess = min(hold, total - durationMillis)
            hold -= excess
            total -= excess
        }
        if total > durationMillis {
            fadeIn -= total - durationMillis
        }
        return PoemTimeline(fadeInMillis: fadeIn, holdMillis: hold, fadeOutMillis: fadeOut)
    }

    /// The opacity of the poem at that moment of the break.
    ///
    /// Reduced motion shows and hides the poem at once, but keeps the same
    /// visible window.
    public func opacity(at elapsedMillis: Int64, reduceMotion: Bool = false) -> Double {
        let total = totalMillis
        guard total > 0 else { return 0 }
        if reduceMotion {
            return (elapsedMillis >= 0 && elapsedMillis < total) ? 1 : 0
        }
        guard elapsedMillis > 0 else { return 0 }
        if fadeInMillis > 0 && elapsedMillis < fadeInMillis {
            return Double(elapsedMillis) / Double(fadeInMillis)
        }
        let fadeOutStart = fadeInMillis + holdMillis
        if elapsedMillis < fadeOutStart {
            return 1
        }
        if fadeOutMillis > 0 && elapsedMillis < total {
            return Double(total - elapsedMillis) / Double(fadeOutMillis)
        }
        return 0
    }

    /// True while the poem is visible.
    public func isVisible(at elapsedMillis: Int64) -> Bool {
        opacity(at: elapsedMillis) > 0
    }
}
