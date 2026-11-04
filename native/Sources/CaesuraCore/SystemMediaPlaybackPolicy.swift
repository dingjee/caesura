import Foundation

/// One media session of the system: the application that reports now playing
/// information and the media item it reports.
///
/// The session is identified by the application — its bundle identifier, the
/// bundle identifier of its parent application and its process identifier —
/// and by the media item, which carries the unique identifier of the session
/// or the identifier of its content item. A session that reports no
/// identifier of a media item is never acted on: the metadata of the media
/// (the title, the artist, the album) is no proof of the identity of an item,
/// so it never decides one.
public struct SystemMediaSession: Equatable {
    /// The bundle identifier of the application that reports the session.
    /// A browser reports the helper that plays the media, so the parent
    /// application below is often the application the user knows.
    public let bundleIdentifier: String
    /// The bundle identifier of the parent application of the session.
    public let parentApplicationBundleIdentifier: String?
    /// The process that reports the session.
    public let processIdentifier: Int?
    /// The identifier of the media item: the unique identifier of the session,
    /// otherwise the identifier of its content item.
    public let mediaItemIdentifier: String?
    /// True when the media of the session plays.
    public let isPlaying: Bool

    public init(bundleIdentifier: String,
                parentApplicationBundleIdentifier: String? = nil,
                processIdentifier: Int? = nil,
                mediaItemIdentifier: String? = nil,
                isPlaying: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.parentApplicationBundleIdentifier = parentApplicationBundleIdentifier
        self.processIdentifier = processIdentifier
        self.mediaItemIdentifier = mediaItemIdentifier
        self.isPlaying = isPlaying
    }
}

/// The rules of the pause of a media session during a break.
///
/// The rules are pure: they read the facts of a session without touching the
/// system. The backend that reads the session and sends the commands lives in
/// the application.
public enum SystemMediaPlaybackPolicy {
    /// The applications whose media keeps playing during a break.
    ///
    /// The list holds the bundle identifiers of the applications. The bundle
    /// identifier of the session and the bundle identifier of its parent
    /// application are both checked: a browser reports the helper that plays
    /// the media, so the application the user knows is the parent.
    public static func keepsPlaying(_ session: SystemMediaSession,
                                    allowedBundleIdentifiers: Set<String>) -> Bool {
        let allowed = Set(allowedBundleIdentifiers.map { $0.lowercased() })
        if allowed.contains(session.bundleIdentifier.lowercased()) { return true }
        if let parent = session.parentApplicationBundleIdentifier,
           allowed.contains(parent.lowercased()) { return true }
        return false
    }

    /// May the session be paused for the break?
    ///
    /// A session that does not play is left alone, a session of an application
    /// that keeps playing is left alone, a session without the identifier of a
    /// media item is left alone — the media item it plays could be anything,
    /// so it could never be resumed with certainty — and a session without a
    /// process is left alone: the application behind it is not known.
    public static func mayPause(_ session: SystemMediaSession,
                                 allowedBundleIdentifiers: Set<String>) -> Bool {
        guard session.isPlaying else { return false }
        guard hasProcessIdentifier(session) else { return false }
        guard hasMediaItemIdentifier(session) else { return false }
        return !keepsPlaying(session, allowedBundleIdentifiers: allowedBundleIdentifiers)
    }

    /// May the playback that was paused for the break be resumed?
    ///
    /// Only the very same session with the very same media item, and only
    /// while it stays paused: a session the user started again, a session
    /// another application took over and a session that plays another item
    /// end the attempt.
    public static func mayResume(remembered: SystemMediaSession,
                                  current: SystemMediaSession?) -> Bool {
        guard let current else { return false }
        guard !current.isPlaying else { return false }
        return isSameSession(remembered, current) && isSameMediaItem(remembered, current)
    }

    /// Is it the very same session? The application, its parent application
    /// and its process have to be the same. The process has to be known on
    /// both sides: a session whose process is gone and an application that
    /// started again are another session.
    public static func isSameSession(_ remembered: SystemMediaSession,
                                     _ current: SystemMediaSession) -> Bool {
        if remembered.bundleIdentifier.lowercased()
            != current.bundleIdentifier.lowercased() { return false }
        let rememberedParent = remembered.parentApplicationBundleIdentifier?.lowercased()
        let currentParent = current.parentApplicationBundleIdentifier?.lowercased()
        if rememberedParent != currentParent { return false }
        guard let rememberedProcess = remembered.processIdentifier,
              rememberedProcess > 0,
              let currentProcess = current.processIdentifier,
              currentProcess > 0 else { return false }
        return rememberedProcess == currentProcess
    }

    /// Is it the very same media item? Only the identifier of the item proves
    /// it — the metadata of the media never does.
    public static func isSameMediaItem(_ remembered: SystemMediaSession,
                                        _ current: SystemMediaSession) -> Bool {
        guard let rememberedItem = remembered.mediaItemIdentifier,
              !rememberedItem.isEmpty else { return false }
        guard let currentItem = current.mediaItemIdentifier,
              !currentItem.isEmpty else { return false }
        return rememberedItem == currentItem
    }

    /// Does the session carry the identifier of a media item?
    public static func hasMediaItemIdentifier(_ session: SystemMediaSession) -> Bool {
        guard let item = session.mediaItemIdentifier else { return false }
        return !item.isEmpty
    }

    /// Does the session carry the identifier of the process that reports it?
    public static func hasProcessIdentifier(_ session: SystemMediaSession) -> Bool {
        guard let process = session.processIdentifier else { return false }
        return process > 0
    }
}
