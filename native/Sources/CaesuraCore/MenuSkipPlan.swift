import Foundation

/// The two skip items of the menu bar menu.
///
/// The menu offers one item per break type: it starts that type at once. The
/// number of minutes is shown only for the type that is planned right now —
/// the countdown of the scheduler is exact for it. A type that is not planned
/// yet gets no number: the menu never invents minutes, and the long break
/// never wears the countdown of the short one.
public enum MenuSkipPlan {
    /// One item of the menu.
    public struct Item: Equatable {
        /// True for the short (Mini) break.
        public let isMini: Bool
        /// The minutes of the wait that are skipped, when the plan of this
        /// type is the current plan (nil: the type starts without a number).
        public let minutes: Int?

        public init(isMini: Bool, minutes: Int?) {
            self.isMini = isMini
            self.minutes = minutes
        }
    }

    /// The items of the menu, in the order they are shown: the short break
    /// first, the long break after it. A type that is disabled has no item.
    public static func items(planner: BreaksPlanner, settings: SettingsStore) -> [Item] {
        let scheduled = planner.scheduledBreakType
        let timeLeft = planner.timeToNextBreak
        var items: [Item] = []
        if settings.getBool("microbreak") {
            items.append(Item(isMini: true,
                              minutes: minutes(type: "microbreak", scheduled: scheduled, timeLeft: timeLeft)))
        }
        if settings.getBool("break") {
            items.append(Item(isMini: false,
                              minutes: minutes(type: "break", scheduled: scheduled, timeLeft: timeLeft)))
        }
        return items
    }

    /// The minutes of the wait that are skipped: only the type that is planned
    /// right now has an exact countdown, and a wait below a minute has no
    /// whole minute to name.
    private static func minutes(type: String, scheduled: String, timeLeft: Int64?) -> Int? {
        guard type == scheduled, let timeLeft, timeLeft > 0 else { return nil }
        let minutes = Int((Double(timeLeft) / 60_000).rounded())
        return minutes >= 1 ? minutes : nil
    }
}
