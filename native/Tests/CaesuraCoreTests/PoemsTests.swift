import Foundation
import CaesuraCore

enum PoemsTests {
    static func registerAll() {
        TestRunner.register("poems: bundled catalog decodes (>=366, unique ids, excerpts <=4)", bundledCatalog)
        TestRunner.register("poems: the poem grows word by word over the breaks", poemGrowsWordByWord)
        TestRunner.register("poems: a mini break reveals one word, a long break four", budgetsPerBreakKind)
        TestRunner.register("poems: the poem is shown completely 1 + E times", completeShowingsCount)
        TestRunner.register("poems: with E = 0 the poem is shown completely once", zeroRepeats)
        TestRunner.register("poems: with E = 9 the poem is shown completely ten times", nineRepeats)
        TestRunner.register("poems: a short poem is never revealed beyond its end", shortPoemCaps)
        TestRunner.register("poems: the poem changes only when it was read and repeated", changesOnlyWhenComplete)
        TestRunner.register("poems: a skipped break changes nothing", skippedBreakChangesNothing)
        TestRunner.register("poems: the same break is counted only once", commitIsIdempotent)
        TestRunner.register("poems: a late session never moves the state back", lateSessionIsIgnored)
        TestRunner.register("poems: the kind of the session decides what is counted", kindDecidesTheCount)
        TestRunner.register("poems: the poem and its progress survive a restart", progressSurvivesRestart)
        TestRunner.register("poems: after a restart a new break still advances the state", restartStillAdvances)
        TestRunner.register("poems: the tokens of the breaks grow inside a run", tokensGrow)
        TestRunner.register("poems: the tokens stay above the committed ones after a restart", tokensSurviveRestart)
        TestRunner.register("poems: an illegal number of repetitions falls back to the default", illegalRepeatsFallBack)
        TestRunner.register("poems: writing the preference notifies once, the state never", notificationCounts)
        TestRunner.register("poems: the progress belongs to the poem, not to the day", progressIsNotPerDay)
        TestRunner.register("poems: the catalog version change resets the rotation and the progress", versionReset)
        TestRunner.register("poems: a corrupt rotation falls back safely", corruptStateFallsBack)
        TestRunner.register("poems: the legacy counter is kept but never read as a progress", legacyCounterIsKept)
        TestRunner.register("poems: the state is written in one piece", stateIsWrittenAtOnce)
        TestRunner.register("poems: a rotation cycle never repeats a poem", noRepeatInCycle)
        TestRunner.register("poems: the cycle reshuffles after the deck is exhausted", cycleReshuffle)
        TestRunner.register("poems: the first poem prefers the anniversary of the day", firstPoemPrefersAnniversary)
        TestRunner.register("poems: the anniversary wins inside the look-ahead window", anniversaryPriority)
        TestRunner.register("poems: a match outside the look-ahead window is ignored", outsideWindowIgnored)
        TestRunner.register("poems: month beats season beats no match", seasonMonthPriority)
        TestRunner.register("poems: empty or broken catalog falls back to nil", unavailableCatalog)
        TestRunner.register("poems: writing the rotation does not notify the settings", rotationDoesNotNotify)
        TestRunner.register("poems: formatter HTML survives the sanitizer", formatter)
    }

    // MARK: Helpers

    final class StubProvider: PoemProvider {
        let stubbedCatalog: PoemCatalog?
        init(catalog: PoemCatalog?) { self.stubbedCatalog = catalog }
        func catalog() throws -> PoemCatalog {
            guard let stubbedCatalog else { throw TestFailure(message: "broken provider") }
            return stubbedCatalog
        }
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    static func temporaryDirectory() -> URL {
        let suffix = UUID().uuidString.prefix(8)
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: base).appendingPathComponent("pm-\(suffix)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func store() -> SettingsStore {
        SettingsStore(url: temporaryDirectory().appendingPathComponent("config.json"))
    }

    /// Deterministic catalog: poem ids "p0".."pN", season/month tags spread so
    /// tests can seed a rotation order and assert on the winner.
    static func makeCatalog(count: Int, version: Int = 1,
                            tag: (Int) -> (seasons: [String], months: [Int], born: String?, died: String?) = { _ in ([], [], nil, nil) }) -> PoemCatalog {
        let poems = (0..<count).map { index -> Poem in
            let tags = tag(index)
            return Poem(id: "p\(index)", title: "Poem \(index)", author: "Author \(index)",
                        lines: ["line \(index)a", "line \(index)b"],
                        excerpt: ["line \(index)a", "line \(index)b"],
                        seasons: tags.seasons, months: tags.months,
                        authorBorn: tags.born, authorDied: tags.died, source: "PoetryDB")
        }
        return PoemCatalog(version: version, language: "en", attribution: PoemCatalog.attribution, poems: poems)
    }

    /// A catalog of poems with six words each, so that the reveal of a poem
    /// takes a known number of breaks.
    static func sixWordCatalog(count: Int, version: Int = 1) -> PoemCatalog {
        let poems = (0..<count).map { index -> Poem in
            Poem(id: "p\(index)", title: "Poem \(index)", author: "Author \(index)",
                 lines: ["Hope is the thing with feathers"],
                 excerpt: ["Hope is the thing with feathers"],
                 seasons: [], months: [], authorBorn: nil, authorDied: nil, source: "PoetryDB")
        }
        return PoemCatalog(version: version, language: "en", attribution: PoemCatalog.attribution, poems: poems)
    }

    /// Seeds a rotation state. A mismatching `catalogVersion` makes the
    /// rotation rebuild itself on the next draw.
    static func seed(_ settings: SettingsStore, order: [String], position: Int = 0,
                     showings: Int = 0, catalogVersion: Int = 1) {
        settings.set(PoemRotation.settingsKey, .object([
            "order": .array(order.map { .string($0) }),
            "position": .int(Int64(position)),
            "showings": .int(Int64(showings)),
            "catalogVersion": .int(Int64(catalogVersion))
        ]))
    }

    static func persistedOrder(_ settings: SettingsStore) -> [String] {
        settings.get(PoemRotation.settingsKey)?.objectValue?["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    static func persistedState(_ settings: SettingsStore) -> [String: SettingsValue] {
        settings.get(PoemRotation.settingsKey)?.objectValue ?? [:]
    }

    /// A rotation over the given catalog.
    static func rotation(_ settings: SettingsStore, _ catalog: PoemCatalog,
                          clock: ManualClock = ManualClock()) -> PoemRotation {
        PoemRotation(provider: StubProvider(catalog: catalog), settings: settings,
                     clock: clock, calendar: utcCalendar())
    }

    /// Runs one break of the rotation: it plans the break and counts it.
    @discardableResult
    static func runBreak(_ rotation: PoemRotation, mini: Bool = true) -> PoemBreakSession? {
        guard let session = rotation.plan(mini: mini, startedAt: 0, durationMillis: 20_000) else {
            return nil
        }
        rotation.commit(session: session)
        return session
    }

    // MARK: Cases

    static func bundledCatalog() throws {
        let catalog = try BundledPoemProvider().catalog()
        try expectTrue(catalog.poems.count >= 366, "need a year of unique poems, got \(catalog.poems.count)")
        try expectEqual(Set(catalog.poems.map(\.id)).count, catalog.poems.count, "ids must be unique")
        try expectEqual(catalog.attribution, PoemCatalog.attribution)
        for poem in catalog.poems {
            try expectTrue((1...4).contains(poem.excerpt.count), "excerpt of \(poem.id): \(poem.excerpt.count) lines")
            let content = poem.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            try expectTrue((2...14).contains(content.count), "line count of \(poem.id): \(content.count)")
            try expectTrue(poem.seasons.allSatisfy(["spring", "summer", "autumn", "winter"].contains))
            try expectTrue(poem.months.allSatisfy { (1...12).contains($0) })
        }
        try expectTrue(catalog.poems.contains { $0.author == "Emily Dickinson" })
    }

    /// The poem of the rotation grows word by word: every break shows one more
    /// word (a Mini break) or four more words (a Long break).
    static func poemGrowsWordByWord() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let first = try expectNotNil(rotation.poem())
        let mini = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(mini.poemId, first.id, "the poem stays between the breaks")
        try expectEqual(mini.revealedBefore, 0)
        try expectEqual(mini.revealedAfter, 1, "a mini break reveals one word")
        try expectEqual(mini.kind, .advancing)
        try expectEqual(mini.mode, .revealing)
        rotation.commit(session: mini)
        try expectEqual(rotation.revealProgress.words, 1)

        let long = try expectNotNil(rotation.plan(mini: false, startedAt: 0, durationMillis: 300_000))
        try expectEqual(long.revealedBefore, 1)
        try expectEqual(long.revealedAfter, 5, "a long break reveals four words")
        rotation.commit(session: long)
        try expectEqual(rotation.revealProgress.words, 5)

        let next = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(next.revealedBefore, 5)
        try expectEqual(next.revealedAfter, 6, "the last word completes the poem")
        try expectEqual(next.kind, .unlocking)
        try expectEqual(next.mode, .full, "the complete poem is shown in full")
    }

    static func budgetsPerBreakKind() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let mini = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(mini.revealedAfter - mini.revealedBefore, 1, "a mini break reveals one word")
        let long = try expectNotNil(rotation.plan(mini: false, startedAt: 0, durationMillis: 300_000))
        try expectEqual(long.revealedAfter - long.revealedBefore, 4, "a long break reveals four words")
    }

    /// The complete poem is shown 1 + E times: once when it is unlocked and
    /// E times more.
    static func completeShowingsCount() throws {
        for extra in [0, 2, 9] {
            let settings = store()
            settings.set(PoemRotation.extraRepeatsKey, .int(Int64(extra)))
            let rotation = self.rotation(settings, sixWordCatalog(count: 3))
            var complete = 0
            var unlockedAt = -1
            var switchedAt = -1
            var firstPoemId = ""
            for index in 0..<40 {
                let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0,
                                                             durationMillis: 20_000))
                if firstPoemId.isEmpty { firstPoemId = session.poemId }
                if session.poemId != firstPoemId {
                    // The rotation moved on: the first poem is done.
                    switchedAt = index
                    break
                }
                if session.mode == .full { complete += 1 }
                if session.kind == .unlocking { unlockedAt = index }
                rotation.commit(session: session)
            }
            try expectEqual(complete, 1 + extra,
                            "the complete poem is shown \(1 + extra) times with E = \(extra)")
            try expectEqual(switchedAt - unlockedAt, extra + 1,
                            "the poem changes \(extra + 1) breaks after the unlock with E = \(extra)")
        }
    }

    static func zeroRepeats() throws {
        let settings = store()
        settings.set(PoemRotation.extraRepeatsKey, .int(0))
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let first = try expectNotNil(rotation.poem())
        // Mini, Mini, Long: the long break unlocks the poem.
        let one = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        rotation.commit(session: one)
        let two = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        rotation.commit(session: two)
        let three = try expectNotNil(rotation.plan(mini: false, startedAt: 0, durationMillis: 300_000))
        try expectEqual(three.kind, .unlocking)
        try expectEqual(three.mode, .full)
        rotation.commit(session: three)
        try expectEqual(rotation.revealProgress.words, 6)
        try expectEqual(rotation.revealProgress.repeats, 0, "the unlock is not a repetition")

        // The next break shows the next poem: there is no repetition at all.
        let four = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(four.poemId != first.id, "the poem changes without a repetition")
        try expectEqual(four.kind, .advancing)
        try expectEqual(four.revealedBefore, 0, "the next poem starts at zero")
        try expectEqual(four.revealedAfter, 1)
    }

    static func nineRepeats() throws {
        let settings = store()
        settings.set(PoemRotation.extraRepeatsKey, .int(9))
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        var complete = 0
        var firstPoemId = ""
        for _ in 0..<40 {
            let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0,
                                                         durationMillis: 20_000))
            if firstPoemId.isEmpty { firstPoemId = session.poemId }
            if session.poemId != firstPoemId { break }
            if session.mode == .full { complete += 1 }
            rotation.commit(session: session)
        }
        try expectEqual(complete, 10, "the complete poem is shown ten times with E = 9")
    }

    /// A poem of two words: the reveal never goes beyond the end of the poem.
    static func shortPoemCaps() throws {
        let settings = store()
        let catalog = PoemCatalog(version: 1, language: "en", attribution: PoemCatalog.attribution,
                                  poems: [Poem(id: "p0", title: "Short", author: "A",
                                              lines: ["one two"], excerpt: ["one two"],
                                              seasons: [], months: [], authorBorn: nil,
                                              authorDied: nil, source: "test")])
        let rotation = self.rotation(settings, catalog)
        let mini = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(mini.revealedAfter, 1)
        rotation.commit(session: mini)
        let long = try expectNotNil(rotation.plan(mini: false, startedAt: 0, durationMillis: 300_000))
        try expectEqual(long.revealedAfter, 2, "a long break never reveals more than the poem has")
        try expectEqual(long.totalWords, 2)
        try expectEqual(long.kind, .unlocking)
        rotation.commit(session: long)
        let again = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(again.revealedAfter, 2, "the poem never grows beyond its end")
        try expectEqual(again.revealedBefore, 2)
    }

    /// The poem changes only when it was read completely and repeated often
    /// enough.
    static func changesOnlyWhenComplete() throws {
        let settings = store()
        settings.set(PoemRotation.extraRepeatsKey, .int(2))
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let first = try expectNotNil(rotation.poem())
        // The poem is not complete: the poem must not change.
        for _ in 0..<3 {
            let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0,
                                                         durationMillis: 20_000))
            try expectEqual(session.poemId, first.id, "an unfinished poem stays")
            rotation.commit(session: session)
        }
        try expectEqual(rotation.revealProgress.words, 3)
        try expectEqual(rotation.poem()?.id, first.id)
    }

    /// A break that was skipped, postponed or cancelled is never counted: the
    /// state stays exactly as it was.
    static func skippedBreakChangesNothing() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let before = rotation.rotationState
        // The break is planned, but it never finishes: nothing is committed.
        _ = rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000)
        let after = rotation.rotationState
        try expectEqual(after.reveal.words, before.reveal.words, "the progress does not move")
        try expectEqual(after.reveal.repeats, before.reveal.repeats)
        try expectEqual(after.position, before.position, "the poem does not change")
        try expectEqual(after.lastCommittedToken, before.lastCommittedToken,
                        "a break that never finished has no token")
    }

    /// The same break is counted only once: the second commit is ignored.
    static func commitIsIdempotent() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(rotation.commit(session: session), "the first commit counts")
        try expectEqual(rotation.revealProgress.words, 1)
        try expectFalse(rotation.commit(session: session), "the second commit is ignored")
        try expectEqual(rotation.revealProgress.words, 1, "the progress moved only once")
    }

    /// A late session of an older break never moves the state back.
    static func lateSessionIsIgnored() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let older = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        let newer = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(newer.token > older.token, "the tokens grow")
        rotation.commit(session: newer)
        try expectEqual(rotation.revealProgress.words, 1)
        try expectFalse(rotation.commit(session: older), "the late session is ignored")
        try expectEqual(rotation.revealProgress.words, 1, "the state was not moved back")
    }

    /// The kind of the session decides what is counted: the break that
    /// completes the poem shows the whole poem as well, but it is no repetition.
    static func kindDecidesTheCount() throws {
        let settings = store()
        settings.set(PoemRotation.extraRepeatsKey, .int(2))
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        // Mini, Mini, Long: the long break unlocks the poem.
        let one = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        rotation.commit(session: one)
        let two = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        rotation.commit(session: two)
        let unlock = try expectNotNil(rotation.plan(mini: false, startedAt: 0, durationMillis: 300_000))
        try expectEqual(unlock.mode, .full, "the unlock shows the whole poem")
        try expectEqual(unlock.kind, .unlocking)
        rotation.commit(session: unlock)
        try expectEqual(rotation.revealProgress.repeats, 0, "the unlock is not a repetition")

        let repeatSession = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(repeatSession.mode, .full, "the repetition shows the whole poem as well")
        try expectEqual(repeatSession.kind, .repeating)
        rotation.commit(session: repeatSession)
        try expectEqual(rotation.revealProgress.repeats, 1, "the repetition counts once")
    }

    /// The poem and its progress survive a restart.
    static func progressSurvivesRestart() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let first = try expectNotNil(rotation.poem())
        runBreak(rotation)
        runBreak(rotation)
        let reloaded = self.rotation(settings, sixWordCatalog(count: 3))
        try expectEqual(reloaded.poem()?.id, first.id, "a restart keeps the poem")
        try expectEqual(reloaded.revealProgress.words, 2, "a restart keeps the progress")
        let session = try expectNotNil(reloaded.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectEqual(session.revealedBefore, 2, "the break continues where it stopped")
        try expectEqual(session.revealedAfter, 3)
    }

    /// After a restart a planned break still advances the state.
    static func restartStillAdvances() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        runBreak(rotation)
        let reloaded = self.rotation(settings, sixWordCatalog(count: 3))
        let session = try expectNotNil(reloaded.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(reloaded.commit(session: session), "the break after the restart counts")
        try expectEqual(reloaded.revealProgress.words, 2, "the progress really moved")
        try expectEqual(reloaded.rotationState.lastCommittedToken, session.token)
    }

    /// The tokens of the breaks grow inside a run.
    static func tokensGrow() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let first = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        let second = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(second.token > first.token, "the tokens grow")
        try expectTrue(rotation.commit(session: first), "the first break counts")
        try expectTrue(rotation.commit(session: second), "the second break counts too")
        try expectEqual(rotation.revealProgress.words, 1,
                        "the second break continues where the first one stopped")
    }

    /// The tokens stay above the committed ones after a restart.
    static func tokensSurviveRestart() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        rotation.commit(session: session)
        let committed = rotation.rotationState.lastCommittedToken
        let reloaded = self.rotation(settings, sixWordCatalog(count: 3))
        let next = try expectNotNil(reloaded.plan(mini: true, startedAt: 0, durationMillis: 20_000))
        try expectTrue(next.token > committed, "the token of the new run is above the committed one")
        try expectEqual(next.token, committed + 1, "the token starts right above the committed one")
    }

    /// An illegal number of repetitions falls back to the default.
    static func illegalRepeatsFallBack() throws {
        for raw in ["-1", "10", "2.5", "true", "\"2\"", "null", "[]", "{}"] {
            try withConfig("{\"poemFullRepeats\":\(raw)}") { settings, _ in
                try expectEqual(settings.getBoundedCount(PoemRotation.extraRepeatsKey), 2,
                                "the value \(raw) falls back to the default")
            }
        }
        // A missing key is the default as well.
        try withConfig("{}") { settings, _ in
            try expectEqual(settings.getBoundedCount(PoemRotation.extraRepeatsKey), 2,
                            "a missing key falls back to the default")
        }
        // Legal values are kept.
        for legal in [0, 2, 9] {
            try withConfig("{\"poemFullRepeats\":\(legal)}") { settings, _ in
                try expectEqual(settings.getBoundedCount(PoemRotation.extraRepeatsKey), legal)
            }
        }
        // A whole config that is not valid JSON is backed up and the defaults
        // are used: that is not a single key fallback.
        try withConfig("{not json") { settings, dir in
            try expectEqual(settings.getBoundedCount(PoemRotation.extraRepeatsKey), 2)
            try expectTrue(FileManager.default.fileExists(atPath:
                dir.appendingPathComponent("malformed-config-backup.json").path),
                           "the broken config is backed up")
            try expectTrue(settings.diagnostics.contains { $0.kind == .malformedReplaced })
        }
    }

    /// Writes a config file, reads it back and removes the directory again.
    static func withConfig(_ json: String,
                           _ body: (SettingsStore, URL) throws -> Void) throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        try body(SettingsStore(url: url), dir)
    }

    /// Writing the preference notifies once, writing the state never notifies.
    static func notificationCounts() throws {
        let settings = store()
        var notifications = 0
        settings.onChange = { _, _ in notifications += 1 }
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        runBreak(rotation)
        try expectEqual(notifications, 0, "the state of the rotation never notifies")
        settings.set(PoemRotation.extraRepeatsKey, .int(3))
        try expectEqual(notifications, 1, "the preference notifies exactly once")
        try expectEqual(settings.getBoundedCount(PoemRotation.extraRepeatsKey), 3)
    }

    /// The progress belongs to the poem, not to the day: midnight does not
    /// reset it.
    static func progressIsNotPerDay() throws {
        let settings = store()
        let first = ManualClock(start: Int64(day(2026, 10, 30).timeIntervalSince1970) * 1000)
        let rotation = self.rotation(settings, sixWordCatalog(count: 3), clock: first)
        runBreak(rotation)
        runBreak(rotation)
        try expectEqual(rotation.revealProgress.words, 2)
        // The next day: a new rotation over the same settings.
        let second = ManualClock(start: Int64(day(2026, 10, 31).timeIntervalSince1970) * 1000)
        let reloaded = self.rotation(settings, sixWordCatalog(count: 3), clock: second)
        try expectEqual(reloaded.revealProgress.words, 2, "midnight does not reset the progress")
        try expectEqual(reloaded.revealProgress.poemId, rotation.revealProgress.poemId)
    }

    /// The catalog version change resets the rotation and the progress.
    static func versionReset() throws {
        let settings = store()
        let catalog = makeCatalog(count: 5, version: 2)
        seed(settings, order: ["gone-1", "gone-2"], position: 2, catalogVersion: 1)
        let rotation = self.rotation(settings, catalog)
        let poem = rotation.poem()
        try expectTrue(catalog.poems.contains { $0.id == poem?.id })
        try expectEqual(rotation.rotationState.catalogVersion, 2)
        try expectEqual(Set(rotation.rotationState.order), Set(catalog.poems.map(\.id)))
        try expectEqual(persistedOrder(settings).count, 5, "the reset order must be persisted")
        try expectEqual(rotation.revealProgress.words, 0, "the progress of the old poem is dropped")
        try expectEqual(rotation.revealProgress.poemId, "")
    }

    /// A corrupt rotation falls back safely: a new poem, no progress, no crash.
    static func corruptStateFallsBack() throws {
        for corrupt in ["[1]", "\"nonsense\"", "7",
                        "{\"order\":\"x\"}",
                        "{\"reveal\":{\"words\":\"seven\"}}",
                        "{\"reveal\":{\"repeats\":-4}}",
                        "{\"position\":\"third\"}"] {
            let settings = store()
            settings.set(PoemRotation.settingsKey,
                         try SettingsValue.from(jsonObject: Data(corrupt.utf8)))
            let rotation = self.rotation(settings, sixWordCatalog(count: 3))
            let poem = rotation.poem()
            try expectNotNil(poem, "a corrupt state still gives a poem")
            try expectEqual(rotation.revealProgress.words, 0, "a corrupt progress starts at zero")
            try expectTrue(rotation.revealProgress.repeats >= 0)
            let session = try expectNotNil(rotation.plan(mini: true, startedAt: 0,
                                                         durationMillis: 20_000))
            try expectEqual(session.revealedBefore, 0)
            try expectTrue(rotation.commit(session: session))
        }
    }

    /// The legacy counter is kept as it is, but it is never read as a progress.
    static func legacyCounterIsKept() throws {
        let settings = store()
        seed(settings, order: (0..<3).map { "p\($0)" }, position: 1, showings: 2)
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        runBreak(rotation)
        let state = persistedState(settings)
        try expectEqual(state["showings"]?.doubleValue, 2, "the legacy counter is kept as it is")
        try expectEqual(rotation.rotationState.showings, 2, "the legacy counter never counts")
        try expectEqual(rotation.revealProgress.words, 1, "the progress comes from the reveal")
        try expectEqual(rotation.rotationState.position, 1, "the poem of the rotation stays")
    }

    /// The whole state is written in one piece, so there is never a state with
    /// a new poem and an old progress.
    static func stateIsWrittenAtOnce() throws {
        let settings = store()
        let rotation = self.rotation(settings, sixWordCatalog(count: 3))
        runBreak(rotation)
        let state = persistedState(settings)
        for key in ["order", "position", "showings", "catalogVersion", "lastCommittedToken", "reveal"] {
            try expectNotNil(state[key], "the state carries \(key)")
        }
        let reveal = state["reveal"]?.objectValue ?? [:]
        try expectNotNil(reveal["poemId"])
        try expectNotNil(reveal["words"])
        try expectNotNil(reveal["repeats"])
        try expectEqual(reveal["words"]?.doubleValue, 1)
    }

    /// Inside a rotation cycle no poem is shown twice.
    static func noRepeatInCycle() throws {
        let settings = store()
        let rotation = PoemRotation(provider: BundledPoemProvider(), settings: settings,
                                     clock: ManualClock(), calendar: utcCalendar())
        var seen = Set<String>()
        for _ in 0..<465 {
            guard let poem = rotation.poem() else { throw TestFailure(message: "no poem") }
            try expectFalse(seen.contains(poem.id), "poem \(poem.id) repeated inside the cycle")
            seen.insert(poem.id)
            // The poem is read completely and repeated before the next one
            // takes its place. Long breaks reveal four words at a time.
            var guardCount = 0
            while true {
                guard let session = rotation.plan(mini: false, startedAt: 0,
                                                  durationMillis: 300_000) else {
                    throw TestFailure(message: "no session")
                }
                rotation.commit(session: session)
                if session.poemId != poem.id { break }
                guardCount += 1
                if guardCount > 2_000 { break }
            }
        }
        try expectEqual(seen.count, 465)
    }

    /// A small catalog is used again after its cycle is over.
    static func cycleReshuffle() throws {
        let settings = store()
        let rotation = self.rotation(settings, makeCatalog(count: 5))
        var seen = Set<String>()
        var repeats = 0
        for _ in 0..<10 {
            guard let poem = rotation.poem() else { throw TestFailure(message: "no poem") }
            if !seen.insert(poem.id).inserted { repeats += 1 }
            var guardCount = 0
            while true {
                guard let session = rotation.plan(mini: false, startedAt: 0,
                                                  durationMillis: 300_000) else {
                    throw TestFailure(message: "no session")
                }
                rotation.commit(session: session)
                if session.poemId != poem.id { break }
                guardCount += 1
                if guardCount > 200 { break }
            }
        }
        try expectTrue(repeats > 0, "a 5-poem cycle must repeat after the cycle is over")
        try expectEqual(seen.count, 5, "every poem of the catalog must be usable again")
    }

    /// The poem the rotation starts with is the one that fits the day best.
    static func firstPoemPrefersAnniversary() throws {
        let settings = store()
        let catalog = makeCatalog(count: 8) { index in
            index == 5 ? ([], [], "07-04", nil) : ([], [], nil, nil)
        }
        let clock = ManualClock(start: Int64(day(2026, 7, 4).timeIntervalSince1970) * 1000)
        let rotation = self.rotation(settings, catalog, clock: clock)
        try expectEqual(rotation.poem()?.id, "p5", "the anniversary poem starts the rotation")
    }

    /// The relevance is scored when a poem is drawn, inside the look-ahead
    /// window of the rotation.
    static func anniversaryPriority() throws {
        let settings = store()
        let catalog = makeCatalog(count: 8) { index in
            index == 5 ? ([], [], "07-04", nil) : ([], [], nil, nil)
        }
        seed(settings, order: (0..<8).map { "p\($0)" })
        let clock = ManualClock(start: Int64(day(2026, 7, 4).timeIntervalSince1970) * 1000)
        let rotation = self.rotation(settings, catalog, clock: clock)
        try expectEqual(rotation.poem()?.id, "p0", "the poem of the running rotation stays")
        // Read the poem of the rotation completely, so that the next break
        // draws the next poem of the rotation.
        var current = "p0"
        for _ in 0..<40 {
            guard let session = rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000) else {
                throw TestFailure(message: "no session")
            }
            rotation.commit(session: session)
            if session.poemId != current { break }
        }
        try expectEqual(rotation.poem()?.id, "p5", "the anniversary poem is swapped into the draw")
    }

    /// A match outside the look-ahead window never wins.
    static func outsideWindowIgnored() throws {
        let settings = store()
        let catalog = makeCatalog(count: 40) { index in
            index == 35 ? ([], [], "07-04", nil) : ([], [], nil, nil)
        }
        seed(settings, order: (0..<40).map { "p\($0)" })
        let clock = ManualClock(start: Int64(day(2026, 7, 4).timeIntervalSince1970) * 1000)
        let rotation = self.rotation(settings, catalog, clock: clock)
        var current = "p0"
        for _ in 0..<40 {
            guard let session = rotation.plan(mini: true, startedAt: 0, durationMillis: 20_000) else {
                throw TestFailure(message: "no session")
            }
            rotation.commit(session: session)
            if session.poemId != current { break }
        }
        try expectEqual(rotation.poem()?.id, "p1", "a match at index 35 is outside the 30-poem window")
    }

    static func seasonMonthPriority() throws {
        let settings = store()
        let catalog = makeCatalog(count: 8) { index in
            switch index {
            case 3: return (["summer"], [], nil, nil)
            case 6: return ([], [7], nil, nil)
            case 7: return (["winter"], [], nil, nil)
            default: return ([], [], nil, nil)
            }
        }
        let july = ManualClock(start: Int64(day(2026, 7, 10).timeIntervalSince1970) * 1000)
        let summer = self.rotation(store(), catalog, clock: july)
        try expectEqual(summer.poem()?.id, "p6", "month match beats season match")
        let december = ManualClock(start: Int64(day(2026, 12, 10).timeIntervalSince1970) * 1000)
        let winter = self.rotation(store(), catalog, clock: december)
        try expectEqual(winter.poem()?.id, "p7", "season match beats no match")
    }

    static func unavailableCatalog() throws {
        let empty = self.rotation(store(), makeCatalog(count: 0))
        try expectFalse(empty.isAvailable)
        try expectNil(empty.poem())

        let broken = PoemRotation(provider: StubProvider(catalog: nil), settings: store(),
                                  clock: ManualClock(), calendar: utcCalendar())
        try expectFalse(broken.isAvailable)
        try expectNil(broken.poem())
        try expectNil(broken.plan(mini: true, startedAt: 0, durationMillis: 20_000))
    }

    /// The rotation is the state of the app itself: writing it must not run
    /// the settings change chain, because that chain restarts the scheduler.
    static func rotationDoesNotNotify() throws {
        let settings = store()
        var notifications = 0
        settings.onChange = { _, _ in notifications += 1 }
        let rotation = self.rotation(settings, makeCatalog(count: 5))
        rotation.poem()
        runBreak(rotation)
        try expectEqual(notifications, 0, "the rotation must not notify the settings")
        try expectNotNil(settings.get(PoemRotation.settingsKey))
        try expectEqual(rotation.rotationState.lastCommittedToken, 1)
    }

    static func formatter() throws {
        let poem = Poem(id: "x", title: "Life & <Time>", author: "Emily Dickinson",
                        lines: ["Hope & despair", "", "sings the tune<without> the words"],
                        excerpt: ["Hope & despair"],
                        seasons: [], months: [], authorBorn: nil, authorDied: nil, source: "PoetryDB")
        let mini = PoemIdeaFormatter.miniBody(poem)
        try expectEqual(mini, "Hope &amp; despair")
        try expectFalse(mini.contains("Emily Dickinson"), "the author is a line of its own")
        try expectFalse(mini.contains(" & "), "raw & must be escaped for the XML sanitizer")
        let miniNodes = IdeaSanitizer.sanitize(mini)
        try expectTrue(miniNodes.contains(.text("Hope & despair", bold: false, italic: false)))
        // The lines of the excerpt are separated by a line break.
        let twoLines = PoemIdeaFormatter.miniBody(Poem(id: "z", title: "t", author: "a",
                                                        lines: [], excerpt: ["one", "two"], seasons: [],
                                                        months: [], authorBorn: nil, authorDied: nil, source: "s"))
        try expectEqual(twoLines, "one<br>two")

        // The author line: on its own, upright.
        let author = PoemIdeaFormatter.author(poem)
        try expectEqual(author, "— Emily Dickinson")
        let authorNodes = IdeaSanitizer.sanitize(author)
        try expectTrue(authorNodes.contains(.text("— Emily Dickinson", bold: false, italic: false)))
        try expectEqual(PoemIdeaFormatter.author(Poem(id: "y", title: "t", author: "",
                                                      lines: [], excerpt: [], seasons: [], months: [],
                                                      authorBorn: nil, authorDied: nil, source: "s")),
                       "", "a poem without an author has no author line")

        let titleNodes = IdeaSanitizer.sanitize(PoemIdeaFormatter.longTitle(poem))
        try expectTrue(titleNodes.contains(.text("Life & <Time>", bold: false, italic: false)))

        let long = PoemIdeaFormatter.longBody(poem)
        try expectTrue(long.contains("Hope &amp; despair<br><br>"), "stanza breaks render as a blank line")
        let longNodes = IdeaSanitizer.sanitize(long)
        let breaks = longNodes.filter { $0 == .lineBreak }.count
        try expectTrue(breaks >= 2, "stanza break, got \(breaks)")
        try expectFalse(longNodes.contains(.text("— Emily Dickinson", bold: false, italic: true)),
                        "the author is not part of the poem text")
        try expectEqual(PoemIdeaFormatter.miniBody(poem), mini, "formatter must be deterministic")
    }
}
