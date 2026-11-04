import Foundation

/// The rules of the video playback that the search needs.
///
/// The rules are pure: they read the facts of the accessibility tree without
/// touching another process. The search itself lives in the application.
public enum VideoPlaybackRules {
    /// Is this subrole the one of a video element? The HTML-AAM mapping gives
    /// the `<video>` element the subrole `AXVideo`; an `<audio>` element
    /// carries `AXAudio` and is never a video.
    ///
    /// The localised role description is never used: it depends on the
    /// language of the system.
    public static func isVideoSubrole(_ subrole: String?) -> Bool {
        subrole == "AXVideo"
    }
}

/// The budget of one search through the accessibility tree of another
/// application.
///
/// The whole search shares **one** budget — every window of the application
/// and every subtree of it alike — so a page with many windows and many
/// videos can never hold the scheduler for longer than the budget allows.
public final class TreeBudget {
    /// The time the search may take.
    public let seconds: Double
    /// The number of elements the search may visit.
    public let maximumElements: Int
    /// The depth the search may go down.
    public let maximumDepth: Int
    /// The number of elements one level may hold.
    public let maximumQueue: Int
    private let deadline: Date
    private var visited = 0
    /// True when the search was cut short: the tree was bigger than the
    /// budget allows. The reason is reported, never hidden.
    public private(set) var isExhausted = false

    public init(seconds: Double, maximumElements: Int,
                maximumDepth: Int = 40, maximumQueue: Int = 1_200) {
        self.seconds = seconds
        self.maximumElements = maximumElements
        self.maximumDepth = maximumDepth
        self.maximumQueue = maximumQueue
        self.deadline = Date().addingTimeInterval(seconds)
    }

    /// Books one element of the tree. False when the budget is gone: the
    /// search has to stop.
    public func spend() -> Bool {
        if visited >= maximumElements || Date() >= deadline {
            isExhausted = true
            return false
        }
        visited += 1
        return true
    }

    /// The number of elements the search visited.
    public var visitedElements: Int { visited }
}
