import Foundation

/// The persisted reveal progress of the poem of the rotation.
///
/// The progress belongs to one poem, not to a day: the poem of the rotation
/// changes when the poem was read completely and repeated often enough, and
/// not because a new day began.
public struct PoemRevealState: Codable, Equatable {
    /// The id of the poem the progress belongs to.
    public var poemId: String
    /// Words of the poem revealed already.
    public var words: Int
    /// How often the complete poem was repeated already.
    public var repeats: Int

    public init(poemId: String = "", words: Int = 0, repeats: Int = 0) {
        self.poemId = poemId
        self.words = max(0, words)
        self.repeats = max(0, repeats)
    }

    init(settingsValue: SettingsValue?) {
        guard let object = settingsValue?.objectValue else {
            self.poemId = ""
            self.words = 0
            self.repeats = 0
            return
        }
        func int(_ key: String) -> Int? {
            guard let value = object[key]?.doubleValue, value.isFinite else { return nil }
            return Int(value)
        }
        self.poemId = object["poemId"]?.stringValue ?? ""
        self.words = max(0, int("words") ?? 0)
        self.repeats = max(0, int("repeats") ?? 0)
    }
    func settingsValue() -> SettingsValue {
        .object([
            "poemId": .string(poemId),
            "words": .int(Int64(words)),
            "repeats": .int(Int64(repeats))
        ])
    }
}

/// Persisted rotation state (settings key `poemRotation`).
///
/// The rotation remembers the poem the breaks show right now and how far that
/// poem was read: the poem grows word by word, it is shown complete once, and
/// it is repeated a few times before the next poem of the rotation takes its
/// place. The state is written back on every showing, so a restart keeps the
/// current poem and its progress.
public struct PoemRotationState: Codable, Equatable {
    /// The ids of the poems of the rotation, in the order they come.
    public var order: [String]
    /// The index of the poem the breaks show right now.
    public var position: Int
    /// How many breaks already showed the current poem.
    ///
    /// Legacy: the counter of the former "the poem is shown in full" model.
    /// It is kept as it is, but it is never read as a progress and never
    /// converted into one.
    public var showings: Int
    public var catalogVersion: Int
    /// The highest token that was committed already.
    ///
    /// It is the water mark of the idempotency: a session with an older token
    /// is ignored, so a late callback never moves the state back.
    public var lastCommittedToken: Int64
    /// The reveal progress of the current poem.
    public var reveal: PoemRevealState

    public init(order: [String] = [], position: Int = 0,
                showings: Int = 0, catalogVersion: Int = 0,
                lastCommittedToken: Int64 = 0, reveal: PoemRevealState = PoemRevealState()) {
        self.order = order
        self.position = position
        self.showings = showings
        self.catalogVersion = catalogVersion
        self.lastCommittedToken = lastCommittedToken
        self.reveal = reveal
    }

    init?(settingsValue: SettingsValue?) {
        guard let object = settingsValue?.objectValue else { return nil }
        func int(_ key: String) -> Int? {
            guard let value = object[key]?.doubleValue, value.isFinite else { return nil }
            return Int(value)
        }
        self.order = object["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.position = int("position") ?? 0
        self.showings = int("showings") ?? 0
        self.catalogVersion = int("catalogVersion") ?? 0
        self.lastCommittedToken = Int64(int("lastCommittedToken") ?? 0)
        self.reveal = PoemRevealState(settingsValue: object["reveal"])
    }

    func settingsValue() -> SettingsValue {
        .object([
            "order": .array(order.map { .string($0) }),
            "position": .int(Int64(position)),
            "showings": .int(Int64(showings)),
            "catalogVersion": .int(Int64(catalogVersion)),
            "lastCommittedToken": .int(lastCommittedToken),
            "reveal": reveal.settingsValue()
        ])
    }
}

/// Inputs of the relevance scoring. Currently calendar-only; future fields
/// (hemisphere, weather) extend this struct without changing callers.
public struct PoemRelevanceContext {
    public var month: Int
    public var monthDay: String
    public var season: String

    public init(month: Int, monthDay: String, season: String) {
        self.month = month
        self.monthDay = monthDay
        self.season = season
    }
}

/// The rotation of the poems the breaks show.
///
/// One poem at a time: it grows word by word over the breaks, it is shown
/// complete once, and it is repeated a few times before the next poem of the
/// rotation takes its place. The poems never repeat inside a rotation cycle
/// (>= 366 poems, so a cycle stays duplicate-free), and the poems that fit the
/// season, the month or the anniversary of the day are preferred inside a
/// small look-ahead window.
///
/// Purely offline; the time comes from the injected `Clock`, the calendar math
/// from the injected `Calendar`.
public final class PoemRotation {
    public static let settingsKey = "poemRotation"
    /// The key of the preference that says how often the complete poem is
    /// repeated.
    public static let extraRepeatsKey = "poemFullRepeats"
    /// The size of the look-ahead window of the relevance scoring.
    public static let windowSize = 30
    /// How often the complete poem is repeated when the user did not choose
    /// a number.
    public static let defaultExtraRepeats = 2
    /// The biggest number of repetitions the preference accepts.
    public static let maxExtraRepeats = 9

    public static let anniversaryScore = 3
    public static let monthScore = 2
    public static let seasonScore = 1

    private let provider: PoemProvider
    private let settings: SettingsStore
    private let clock: Clock
    private let calendar: Calendar
    private var catalog: PoemCatalog?
    private var poemById: [String: Poem] = [:]
    private var state = PoemRotationState()
    /// The token of the next planned break.
    ///
    /// It starts above every committed token (also after a restart), so a late
    /// session of an older run can never move the state back.
    private var nextToken: Int64 = 1
    private lazy var monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }()

    public init(provider: PoemProvider, settings: SettingsStore,
                clock: Clock = SystemClock(), calendar: Calendar = .current) {
        self.provider = provider
        self.settings = settings
        self.clock = clock
        self.calendar = calendar
        do {
            let catalog = try provider.catalog()
            self.catalog = catalog
            self.poemById = Dictionary(catalog.poems.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            Log.info("Caesura: poem catalog loaded (\(catalog.poems.count) poems, version \(catalog.version))")
        } catch {
            Log.error("Caesura: poem catalog unavailable: \(error)")
        }
        if let stored = PoemRotationState(settingsValue: settings.get(Self.settingsKey)) {
            state = stored
        }
        nextToken = state.lastCommittedToken + 1
    }

    /// False when the catalog is missing/empty/undecodable; callers fall back
    /// to empty break ideas (same as `ideas: false`).
    public var isAvailable: Bool {
        guard let catalog else { return false }
        return !catalog.poems.isEmpty
    }

    public var rotationState: PoemRotationState { state }

    /// The reveal progress of the current poem.
    public var revealProgress: PoemRevealState { state.reveal }

    /// How often the complete poem may be repeated.
    ///
    /// The value of the preference, read at the moment the break is planned.
    /// A missing or illegal value falls back to the default.
    public var extraRepeatsLimit: Int {
        settings.getBoundedCount(Self.extraRepeatsKey)
    }

    /// The poem the breaks show right now.
    ///
    /// The poem does not change while it is shown: it changes when it was read
    /// completely and repeated often enough (see `plan(...)`).
    public func poem() -> Poem? {
        guard let catalog, !catalog.poems.isEmpty else { return nil }
        ensureRotation(catalog: catalog)
        guard !state.order.isEmpty, state.position < state.order.count else { return nil }
        return poemById[state.order[state.position]]
    }

    /// Plans the poem of the next break.
    ///
    /// The plan captures everything the break needs: the poem, the part of it
    /// the break shows and the number of the repetitions it may count. It is
    /// immutable afterwards — a changed preference, a new day or a rebuilt
    /// window never changes what the running break shows.
    ///
    /// The plan is the only place where the poem of the rotation changes: when
    /// the poem was read completely and repeated often enough, the next break
    /// gets the next poem of the rotation.
    public func plan(mini: Bool, startedAt: Int64, durationMillis: Int64) -> PoemBreakSession? {
        plan(mini: mini, startedAt: startedAt, durationMillis: durationMillis,
             extraRepeats: extraRepeatsLimit)
    }

    /// Plans the poem of the next break with an explicit number of repetitions.
    public func plan(mini: Bool, startedAt: Int64, durationMillis: Int64,
                     extraRepeats: Int) -> PoemBreakSession? {
        guard let catalog, !catalog.poems.isEmpty else { return nil }
        ensureRotation(catalog: catalog)
        let limit = min(max(extraRepeats, 0), Self.maxExtraRepeats)
        guard var current = poem() else { return nil }
        var words = revealedWords(for: current.id)
        var repeats = revealedRepeats(for: current.id)
        words = min(max(words, 0), totalWords(of: current))
        repeats = min(max(repeats, 0), limit)

        if words >= totalWords(of: current), repeats >= limit {
            // The poem is complete and repeated often enough: the next break
            // shows the next poem of the rotation. This is the only place where
            // the poem changes, and it happens while the break is planned.
            moveToNextPoem(catalog: catalog)
            state.reveal = PoemRevealState()
            persist()
            guard let next = poem() else { return nil }
            current = next
            words = 0
            repeats = 0
        }

        let total = totalWords(of: current)
        let before: Int
        let after: Int
        if words >= total {
            // The poem is complete: the break shows it again.
            before = total
            after = total
        } else {
            let interval = PoemReveal.interval(totalWords: total, mini: mini,
                                               revealedBefore: words)
            before = interval.before
            after = interval.after
        }
        let token = allocateToken()
        return PoemBreakSession(poemId: current.id, title: current.title, author: current.author,
                                lines: current.lines, mini: mini, startedAt: startedAt,
                                durationMillis: durationMillis,
                                kind: PoemReveal.kind(revealedBefore: before,
                                                      revealedAfter: after,
                                                      totalWords: total),
                                mode: PoemReveal.mode(revealedAfter: after, totalWords: total),
                                revealedBefore: before, revealedAfter: after,
                                totalWords: total, extraRepeatsAtStart: repeats,
                                extraRepeatsLimit: limit, token: token)
    }

    /// Counts the break that ran completely.
    ///
    /// The session decides what is counted: a break that revealed new words
    /// moves the reveal forward, a break that completed the poem for the first
    /// time only completes it, and a break that shows the complete poem again
    /// counts one repetition.
    ///
    /// The commit is idempotent: a session whose token is not above the water
    /// mark of the committed tokens is ignored, so a late callback or a second
    /// commit of the same break never moves the state back.
    @discardableResult
    public func commit(session: PoemBreakSession) -> Bool {
        guard session.token > state.lastCommittedToken else { return false }
        state.lastCommittedToken = session.token
        switch session.kind {
        case .advancing, .unlocking:
            state.reveal = PoemRevealState(poemId: session.poemId,
                                           words: session.revealedAfter,
                                           repeats: session.extraRepeatsAtStart)
        case .repeating:
            state.reveal = PoemRevealState(poemId: session.poemId,
                                           words: session.totalWords,
                                           repeats: session.extraRepeatsAtStart + 1)
        }
        persist()
        return true
    }

    // MARK: Rotation internals

    /// The words revealed already of that poem. A progress of another poem is
    /// never borrowed.
    private func revealedWords(for poemId: String) -> Int {
        state.reveal.poemId == poemId ? state.reveal.words : 0
    }

    private func revealedRepeats(for poemId: String) -> Int {
        state.reveal.poemId == poemId ? state.reveal.repeats : 0
    }

    private func totalWords(of poem: Poem) -> Int {
        PoemWords.count(in: poem.lines)
    }

    /// The token of the next planned break. The tokens grow inside the run and
    /// stay above every committed token after a restart.
    private func allocateToken() -> Int64 {
        let token = nextToken
        nextToken += 1
        return token
    }

    /// A mismatching `catalogVersion` (or an empty/exhausted order after a
    /// catalog change) restarts the rotation so ids never misalign. The reveal
    /// progress belongs to the old poem then and starts at zero again.
    private func ensureRotation(catalog: PoemCatalog) {
        let catalogIds = catalog.poems.map(\.id)
        let needsReset = state.catalogVersion != catalog.version || state.order.isEmpty
            || Set(state.order) != Set(catalogIds) || state.position >= state.order.count
        guard needsReset else { return }
        state.order = Self.shuffled(catalogIds)
        state.position = 0
        state.showings = 0
        state.catalogVersion = catalog.version
        state.reveal = PoemRevealState()
        applyRelevance(catalog: catalog)
        persist()
    }

    /// The next poem of the rotation: the position moves on, the deck is
    /// reshuffled at the end of the cycle and the relevance scoring picks the
    /// poem that fits the day best inside the look-ahead window.
    private func moveToNextPoem(catalog: PoemCatalog) {
        state.position += 1
        if state.position >= state.order.count {
            state.order = Self.shuffled(state.order)
            state.position = 0
        }
        applyRelevance(catalog: catalog)
    }

    /// Swaps the poem of the current position with the one that fits the day
    /// best inside the look-ahead window.
    ///
    /// The scoring runs when a poem is drawn, never while it is shown: a poem
    /// that is already shown must not be replaced by a better scoring one.
    private func applyRelevance(catalog: PoemCatalog) {
        let windowEnd = min(state.position + Self.windowSize, state.order.count)
        guard windowEnd > state.position else { return }
        let context = relevanceContext(for: now())
        var bestIndex: Int?
        var bestScore = 0
        for index in state.position..<windowEnd {
            guard let poem = poemById[state.order[index]] else { continue }
            let score = Self.relevance(of: poem, context: context)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        if let bestIndex, bestIndex != state.position {
            state.order.swapAt(state.position, bestIndex)
        }
    }

    private func persist() {
        // The rotation is the state of the app itself: writing it must not run
        // the settings change chain, because that chain reinitializes parts of
        // the app and restarts the scheduler.
        settings.setWithoutNotification(Self.settingsKey, state.settingsValue())
    }

    private func now() -> Date {
        Date(timeIntervalSince1970: Double(clock.nowMillis) / 1000)
    }

    private func relevanceContext(for date: Date) -> PoemRelevanceContext {
        PoemRelevanceContext(month: calendar.component(.month, from: date),
                             monthDay: monthDayFormatter.string(from: date),
                             season: Self.season(forMonth: calendar.component(.month, from: date)))
    }

    /// Anniversary (born or died today) beats the current month beats the
    /// current season; scores only rank, they are not summed.
    public static func relevance(of poem: Poem, context: PoemRelevanceContext) -> Int {
        if poem.authorBorn == context.monthDay || poem.authorDied == context.monthDay {
            return anniversaryScore
        }
        var score = 0
        if poem.months.contains(context.month) {
            score = max(score, monthScore)
        }
        if poem.seasons.contains(context.season) {
            score = max(score, seasonScore)
        }
        return score
    }

    /// Meteorological seasons, northern hemisphere. Southern-hemisphere offset
    /// belongs to a future `PoemRelevanceContext.hemisphere`.
    public static func season(forMonth month: Int) -> String {
        switch month {
        case 12, 1, 2: return "winter"
        case 3...5: return "spring"
        case 6...8: return "summer"
        default: return "autumn"
        }
    }

    static func shuffled(_ ids: [String]) -> [String] {
        var array = ids
        guard array.count > 1 else { return array }
        for index in stride(from: array.count - 1, to: 0, by: -1) {
            let swap = Int.random(in: 0...index)
            array.swapAt(index, swap)
        }
        return array
    }
}
