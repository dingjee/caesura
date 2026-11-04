import Foundation
import CaesuraCore

enum SystemMediaPlaybackPolicyTests {
    static func registerAll() {
        TestRunner.register("media policy: the allowlist matches the bundle and the parent",
                            allowlist)
        TestRunner.register("media policy: only a playing session with a media item is paused",
                            pause)
        TestRunner.register("media policy: the resume needs the same session, the same item "
                            + "and a session that still waits", resume)
        TestRunner.register("media policy: the default settings carry the allowlist",
                            defaults)
    }

    /// A session of the tests.
    static func session(bundle: String = "com.example.player",
                        parent: String? = nil,
                        process: Int? = 4242,
                        item: String? = "item-1",
                        playing: Bool = true) -> SystemMediaSession {
        SystemMediaSession(bundleIdentifier: bundle,
                           parentApplicationBundleIdentifier: parent,
                           processIdentifier: process,
                           mediaItemIdentifier: item,
                           isPlaying: playing)
    }

    static func allowlist() throws {
        let allowed: Set<String> = ["com.spotify.client", "com.example.host"]
        // The bundle identifier of the session itself.
        try expectTrue(SystemMediaPlaybackPolicy.keepsPlaying(
            session(bundle: "com.spotify.client"), allowedBundleIdentifiers: allowed))
        // The parent application of the session: a browser reports the helper
        // that plays the media.
        try expectTrue(SystemMediaPlaybackPolicy.keepsPlaying(
            session(bundle: "com.apple.WebKit.GPU", parent: "com.spotify.client"),
            allowedBundleIdentifiers: allowed))
        // The identity of an application is not case sensitive.
        try expectTrue(SystemMediaPlaybackPolicy.keepsPlaying(
            session(bundle: "com.Example.Host"), allowedBundleIdentifiers: allowed))
        // Another application keeps no promise.
        try expectFalse(SystemMediaPlaybackPolicy.keepsPlaying(
            session(bundle: "com.example.other", parent: "com.example.unlisted"),
            allowedBundleIdentifiers: allowed))
        // An empty list allows nothing.
        try expectFalse(SystemMediaPlaybackPolicy.keepsPlaying(
            session(bundle: "com.spotify.client"), allowedBundleIdentifiers: []))
    }

    static func pause() throws {
        let allowed: Set<String> = ["com.spotify.client"]
        // A session that plays and carries the identifier of a media item.
        try expectTrue(SystemMediaPlaybackPolicy.mayPause(
            session(), allowedBundleIdentifiers: allowed))
        // A session that does not play is left alone.
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(playing: false), allowedBundleIdentifiers: allowed))
        // A session of an application that keeps playing is left alone.
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(bundle: "com.spotify.client"), allowedBundleIdentifiers: allowed))
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(bundle: "com.apple.WebKit.GPU", parent: "com.spotify.client"),
            allowedBundleIdentifiers: allowed))
        // A session without the identifier of a media item is left alone: the
        // item it plays could be anything.
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(item: nil), allowedBundleIdentifiers: allowed))
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(item: ""), allowedBundleIdentifiers: allowed))
        // A session without the process that reports it is left alone: the
        // application behind it is not known.
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(process: nil), allowedBundleIdentifiers: allowed))
        try expectFalse(SystemMediaPlaybackPolicy.mayPause(
            session(process: 0), allowedBundleIdentifiers: allowed))
    }

    static func resume() throws {
        let remembered = session(parent: "com.example.host")
        func paused(bundle: String = "com.example.player", parent: String? = "com.example.host",
                    process: Int? = 4242, item: String? = "item-1") -> SystemMediaSession {
            session(bundle: bundle, parent: parent, process: process, item: item, playing: false)
        }
        try expectTrue(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused()))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: remembered))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: nil))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(bundle: "com.example.other")))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(parent: "com.example.other")))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(parent: nil)))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(process: 4343)))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(process: nil)))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(item: "item-2")))
        try expectFalse(SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: paused(item: nil)))
    }

    static func defaults() throws {
        let value = DefaultSettings.values[MediaAllowedApplication.settingKey]
        try expectEqual(value, .array(MediaAllowedApplication.defaults.map(\.settingsValue)))
        try expectTrue(SettingsPolicy.arrayKeys.contains(MediaAllowedApplication.settingKey))
    }
}
