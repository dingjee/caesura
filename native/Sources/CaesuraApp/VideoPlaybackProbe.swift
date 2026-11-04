import AppKit
import CaesuraCore

/// Opt-in probe of the rules of the video playback (development only).
///
/// The probe walks an in-memory accessibility tree — no other application is
/// touched, no media is played, no permission is asked for and no window
/// shows. It checks the rules the search has to keep:
///
/// - the play/pause control of a video element is found and read,
/// - an audio element is never a video,
/// - a control outside a video element counts only for a known native player
///   in a window in fullscreen,
/// - a paused video never hides a video that plays,
/// - the whole search shares one budget: many windows cannot hold it,
/// - a control that is gone is never pressed again, and a video that was
///   replaced is never resumed.
///
/// The last part drives the **real** controller: the pause and the resume
/// run through `pauseIfNeeded()` and `resumeIfNeeded()` with an injected
/// target and an injected observation, so the rules of the controller itself
/// are checked and not only the search.
enum VideoPlaybackProbe {
    /// A fake element of the accessibility tree.
    ///
    /// The web players flip their label between "Pause" and "Play" when the
    /// control is pressed: the fake does the same, so the confirmation of a
    /// press can be checked.
    final class FakeElement: AccessibilityElement {
        var role: String?
        var domIdentifier: String?
        var domClasses: [String] = []
        var subrole: String?
        var names: [String]
        var supportsPress: Bool
        var children: [any AccessibilityElement] = []
        var parent: (any AccessibilityElement)?
        var window: (any AccessibilityElement)?
        var url: String?
        var title: String?
        var processIdentifier: pid_t
        var isFullscreenWindow: Bool
        /// The names the element carries after a press.
        var namesAfterPress: [String]?
        /// The names the element carried before the first press.
        private let originalNames: [String]
        /// How often the element was pressed.
        private(set) var pressCount = 0

        init(role: String?, subrole: String? = nil, names: [String] = [],
             supportsPress: Bool = true, url: String? = nil, title: String? = nil,
             processIdentifier: pid_t = 4_242, isFullscreenWindow: Bool = false,
             namesAfterPress: [String]? = nil) {
            self.role = role
            self.subrole = subrole
            self.names = names
            self.supportsPress = supportsPress
            self.url = url
            self.title = title
            self.processIdentifier = processIdentifier
            self.isFullscreenWindow = isFullscreenWindow
            self.namesAfterPress = namesAfterPress
            self.originalNames = names
        }

        /// The web players flip their label between "Pause" and "Play" every
        /// time the control is pressed.
        func press() -> Bool {
            pressCount += 1
            if let namesAfterPress {
                names = pressCount % 2 == 1 ? namesAfterPress : originalNames
            }
            return true
        }

        func isSameElement(as other: any AccessibilityElement) -> Bool {
            other === self
        }

        /// Adds a child and returns it.
        @discardableResult
        func add(_ child: FakeElement) -> FakeElement {
            child.parent = self
            if child.window == nil, let window = self.window ?? (self.role == "AXWindow" ? self : nil) {
                child.window = window
            }
            children.append(child)
            return child
        }
    }

    /// A window with a video element and a play/pause control.
    static func videoWindow(name: String = "Page", fullscreen: Bool = false,
                            mediaURL: String? = "https://example.test/movie.mp4")
        -> (window: FakeElement, video: FakeElement, control: FakeElement) {
        let video = FakeElement(role: "AXGroup", subrole: "AXVideo", url: mediaURL)
        let control = FakeElement(role: "AXButton", names: ["Pause"], namesAfterPress: ["Play"])
        video.add(control)
        let page = FakeElement(role: "AXWebArea", title: name)
        page.add(video)
        let window = FakeElement(role: "AXWindow", title: name, isFullscreenWindow: fullscreen)
        window.add(page)
        return (window, video, control)
    }

    /// The target the probe pretends to look at.
    static let target = VideoPlayback.Target(bundleIdentifier: "com.example.player",
                                              processIdentifier: 4_242,
                                              name: "Example")

    /// A controller that looks at the fake tree of the probe.
    static func makeController(for observation: VideoPlayback.Observation) -> VideoPlaybackController {
        let controller = VideoPlaybackController()
        controller.targetProvider = { target }
        controller.observer = { _ in observation }
        return controller
    }

    /// The actual Safari YouTube shape: no AXVideo, a stable player group
    /// and a sibling control bar under the document.
    static func youtubeWindow(url: String = "https://www.youtube.com/watch?v=first",
                              fullscreen: Bool = false)
        -> (window: FakeElement, page: FakeElement, player: FakeElement, control: FakeElement) {
        let window = FakeElement(role: "AXWindow", title: "Page", isFullscreenWindow: fullscreen)
        let page = FakeElement(role: "AXWebArea", url: url)
        window.add(page)
        let player = FakeElement(role: "AXGroup")
        player.domIdentifier = "movie_player"
        player.domClasses = ["html5-video-player"]
        page.add(player)
        // The real labels of the YouTube player: "Pause keyboard shortcut k"
        // while it plays and "Play keyboard shortcut k" while it is paused.
        let control = FakeElement(role: "AXButton",
                                   names: ["Pause keyboard shortcut k"],
                                   namesAfterPress: ["Play keyboard shortcut k"])
        control.domClasses = ["ytp-play-button", "ytp-button"]
        player.add(control)
        return (window, page, player, control)
    }

    static func youtubeChecks() -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func search(_ window: FakeElement) -> VideoPlayback.Search {
            VideoPlayback.search(in: window, budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                 allowOutsideVideo: false)
        }
        for fullscreen in [false, true] {
            let tree = youtubeWindow(fullscreen: fullscreen)
            let found = search(tree.window)
            let prefix = fullscreen ? "youtubeFullscreen" : "youtubeWindow"
            checks[prefix + "FoundWithoutAXVideo"] = found.verdict == .pause
                && found.container === tree.player && found.control === tree.control
            let controller = makeController(for: VideoPlayback.Observation(state: .playing,
                window: tree.window, container: found.container, control: found.control))
            controller.pauseIfNeeded()
            checks[prefix + "PausedOnce"] = controller.didPause && tree.control.pressCount == 1
            controller.resumeIfNeeded()
            checks[prefix + "ResumedOnce"] = !controller.didPause && tree.control.pressCount == 2
        }
        for url in ["https://example.test/watch?v=x", "https://youtube.com.example.test/watch?v=x",
                    "https://music.youtube.com/watch?v=x", "http://www.youtube.com/watch?v=x",
                    "https://www.youtube.com:444/watch?v=x"] {
            let tree = youtubeWindow(url: url)
            checks["rejectOrigin:" + url] = search(tree.window).verdict == nil
        }
        let missingID = youtubeWindow()
        missingID.player.domIdentifier = "other"
        checks["youtubeRejectMissingPlayerID"] = search(missingID.window).verdict == nil
        let missingClass = youtubeWindow()
        missingClass.player.domClasses = []
        checks["youtubeRejectMissingPlayerClass"] = search(missingClass.window).verdict == nil
        let unknownButton = youtubeWindow()
        unknownButton.control.domClasses = []
        checks["youtubeRejectGenericPause"] = search(unknownButton.window).verdict == nil
        let unreadable = youtubeWindow()
        unreadable.control.names = ["Play/Pause"]
        checks["youtubeRejectUnknownState"] = search(unreadable.window).verdict == nil
        let disabled = youtubeWindow()
        disabled.control.supportsPress = false
        checks["youtubeRejectUnpressable"] = search(disabled.window).verdict == nil
        // A play button that sits outside the player group is not the player:
        // only a control inside the player may be acted on.
        let strayWindow = FakeElement(role: "AXWindow", title: "Page")
        let strayPage = FakeElement(role: "AXWebArea", url: "https://www.youtube.com/watch?v=first")
        strayWindow.add(strayPage)
        let strayPlayer = FakeElement(role: "AXGroup")
        strayPlayer.domIdentifier = "movie_player"
        strayPlayer.domClasses = ["html5-video-player"]
        strayPage.add(strayPlayer)
        let stray = FakeElement(role: "AXButton",
                                names: ["Pause keyboard shortcut k"],
                                namesAfterPress: ["Play keyboard shortcut k"])
        stray.domClasses = ["ytp-play-button", "ytp-button"]
        strayPage.add(stray)
        checks["youtubeRejectButtonOutsidePlayer"] = search(strayWindow).verdict == nil
        // An observation that lost its document or its parent is never acted
        // on: nothing is pressed at all.
        let lostOrigin = youtubeWindow()
        lostOrigin.page.url = nil
        let lostOriginController = makeController(for: VideoPlayback.Observation(state: .playing,
            window: lostOrigin.window, container: lostOrigin.player, control: lostOrigin.control))
        lostOriginController.pauseIfNeeded()
        checks["youtubePauseRejectLostOrigin"] = lostOrigin.control.pressCount == 0
            && !lostOriginController.didPause
        let lostParent = youtubeWindow()
        lostParent.control.parent = lostParent.page
        let lostParentController = makeController(for: VideoPlayback.Observation(state: .playing,
            window: lostParent.window, container: lostParent.player, control: lostParent.control))
        lostParentController.pauseIfNeeded()
        checks["youtubePauseRejectLostParent"] = lostParent.control.pressCount == 0
            && !lostParentController.didPause
        let quiet = youtubeWindow()
        quiet.control.names = ["Play keyboard shortcut k"]
        let quietResult = search(quiet.window)
        let quietController = makeController(for: VideoPlayback.Observation(state: .paused,
            window: quiet.window, container: quietResult.container, control: quietResult.control))
        quietController.pauseIfNeeded()
        checks["youtubeInitiallyPausedUntouched"] = quietResult.verdict == .play && quiet.control.pressCount == 0
        for change in ["navigation", "origin", "player", "button", "window", "userPlayback"] {
            let tree = youtubeWindow()
            let controller = makeController(for: VideoPlayback.Observation(state: .playing,
                window: tree.window, container: tree.player, control: tree.control))
            controller.pauseIfNeeded()
            switch change {
            case "navigation": tree.page.url = "https://www.youtube.com/watch?v=second"
            case "origin": tree.page.url = "https://example.test/watch?v=first"
            case "player": tree.player.domIdentifier = "replaced"
            case "button": tree.control.domClasses = []
            case "window": tree.window.title = nil
            default: _ = tree.control.press()
            }
            let before = tree.control.pressCount
            controller.resumeIfNeeded()
            checks["youtubeResumeReject:" + change] = tree.control.pressCount == before
        }
        let moved = youtubeWindow()
        let controller = makeController(for: VideoPlayback.Observation(state: .playing,
            window: moved.window, container: moved.player, control: moved.control))
        controller.pauseIfNeeded()
        moved.control.parent = moved.page
        controller.resumeIfNeeded()
        checks["youtubeResumeRejectReparentedButton"] = moved.control.pressCount == 1
        let limited = youtubeWindow()
        let budget = TreeBudget(seconds: 1, maximumElements: 3)
        checks["youtubeSharesSearchBudget"] = VideoPlayback.search(in: limited.window,
            budget: budget, allowOutsideVideo: false).verdict == nil && budget.isExhausted
        return checks
    }

    /// Runs the probe and returns its checks.
    @MainActor
    static func run() -> [String: Any] {
        // 1. A video in a window of the normal size: the control of the video
        //    element is found and the video element is remembered with it.
        let video = videoWindow()
        let found = VideoPlayback.search(in: video.window,
                                         budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                         allowOutsideVideo: false)
        let videoIsFound = found.verdict == .pause
            && found.control === video.control
            && found.container === video.video

        // 2. An audio element is never a video: its control is left alone.
        let audio = FakeElement(role: "AXGroup", subrole: "AXAudio")
        let audioControl = FakeElement(role: "AXButton", names: ["Pause"], namesAfterPress: ["Play"])
        audio.add(audioControl)
        let audioPage = FakeElement(role: "AXWebArea")
        audioPage.add(audio)
        let audioWindow = FakeElement(role: "AXWindow")
        audioWindow.add(audioPage)
        let audioFound = VideoPlayback.search(in: audioWindow,
                                              budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                              allowOutsideVideo: false)
        let audioIsNotAVideo = audioFound.verdict == nil && audioControl.pressCount == 0

        // 3. A control outside a video element counts only for a native
        //    player in a window in fullscreen.
        let plain = FakeElement(role: "AXButton", names: ["Pause"], namesAfterPress: ["Play"])
        let plainPage = FakeElement(role: "AXWebArea")
        plainPage.add(plain)
        let plainWindow = FakeElement(role: "AXWindow", title: "Music", isFullscreenWindow: true)
        plainWindow.add(plainPage)
        let plainAsBrowser = VideoPlayback.search(in: plainWindow,
                                                  budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                                  allowOutsideVideo: false)
        let plainAsPlayer = VideoPlayback.search(in: plainWindow,
                                                 budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                                 allowOutsideVideo: true)
        let plainNeedsTheNativePlayer = plainAsBrowser.verdict == nil
            && plainAsPlayer.verdict == .pause

        // 4. A paused video never hides a video that plays: the playing one
        //    wins.
        let pausedVideo = FakeElement(role: "AXGroup", subrole: "AXVideo")
        pausedVideo.add(FakeElement(role: "AXButton", names: ["Play"]))
        let playingVideo = FakeElement(role: "AXGroup", subrole: "AXVideo")
        let playingControl = FakeElement(role: "AXButton", names: ["Pause"], namesAfterPress: ["Play"])
        playingVideo.add(playingControl)
        let bothPage = FakeElement(role: "AXWebArea")
        bothPage.add(pausedVideo)
        bothPage.add(playingVideo)
        let bothWindow = FakeElement(role: "AXWindow")
        bothWindow.add(bothPage)
        let bothFound = VideoPlayback.search(in: bothWindow,
                                             budget: TreeBudget(seconds: 1, maximumElements: 2_500),
                                             allowOutsideVideo: false)
        let playingWins = bothFound.verdict == .pause && bothFound.control === playingControl

        // 5. The search shares one budget: many windows cannot hold it.
        let sharedBudget = TreeBudget(seconds: 1, maximumElements: 40)
        var searched = 0
        for _ in 0..<20 {
            let page = videoWindow()
            let result = VideoPlayback.search(in: page.window, budget: sharedBudget,
                                              allowOutsideVideo: false)
            if result.verdict == nil { break }
            searched += 1
        }
        let budgetIsShared = sharedBudget.isExhausted && searched < 20

        // 6. The controller pauses a playing video exactly once and resumes
        //    it exactly once.
        let round = videoWindow()
        let playing = VideoPlayback.Observation(state: .playing, window: round.window,
                                                container: round.video, control: round.control)
        let controller = makeController(for: playing)
        controller.pauseIfNeeded()
        let pausedOnce = round.control.pressCount == 1 && controller.didPause
        // A second pause does nothing: the playback is already remembered.
        controller.pauseIfNeeded()
        let pausedOnlyOnce = round.control.pressCount == 1
        controller.resumeIfNeeded()
        let resumedOnce = round.control.pressCount == 2 && !controller.didPause
        // A second resume does nothing either.
        controller.resumeIfNeeded()
        let resumedOnlyOnce = round.control.pressCount == 2

        // 7. A video that is paused already is left alone.
        let quiet = videoWindow()
        let quietController = makeController(for: VideoPlayback.Observation(state: .paused, window: quiet.window,
                                                                        container: quiet.video,
                                                                        control: quiet.control))
        quietController.pauseIfNeeded()
        let pausedVideoIsLeftAlone = quiet.control.pressCount == 0 && !quietController.didPause

        // 8. A video that was replaced while the break ran is not resumed.
        let replaced = videoWindow()
        let replacedController = makeController(for: VideoPlayback.Observation(state: .playing, window: replaced.window,
                                                                             container: replaced.video,
                                                                             control: replaced.control))
        replacedController.pauseIfNeeded()
        replaced.video.url = "https://example.test/other.mp4"
        replacedController.resumeIfNeeded()
        let replacedIsNotResumed = replaced.control.pressCount == 1

        // 9. A target that is gone is never pressed again.
        let vanished = videoWindow()
        let vanishedController = makeController(for: VideoPlayback.Observation(state: .playing, window: vanished.window,
                                                                           container: vanished.video,
                                                                           control: vanished.control))
        vanishedController.pauseIfNeeded()
        vanished.control.names = []
        vanishedController.resumeIfNeeded()
        let vanishedIsNotResumed = vanished.control.pressCount == 1

        // 10. A video the user started again is not resumed a second time.
        let userStarted = videoWindow()
        let userController = makeController(for: VideoPlayback.Observation(state: .playing, window: userStarted.window,
                                                                       container: userStarted.video,
                                                                       control: userStarted.control))
        userController.pauseIfNeeded()
        // The user pressed the control themselves: the video plays again.
        _ = userStarted.control.press()
        userController.resumeIfNeeded()
        let userPlaybackIsLeftAlone = userStarted.control.pressCount == 2

        // 11. Two wrappers around one accessibility element are the same
        //     element: the identity of another process is not the identity
        //     of the object that carries it.
        let systemWide = AXUIElementCreateSystemWide()
        let first = VideoPlayback.AXElement(systemWide)
        let second = VideoPlayback.AXElement(systemWide)
        let ownApplication = VideoPlayback.AXElement(AXUIElementCreateApplication(getpid()))
        let sameElementIsTheSame = first.isSameElement(as: second)
            && !first.isSameElement(as: ownApplication)

        var checks: [String: Any] = [
            "measured": true,
            "videoIsFound": videoIsFound,
            "audioIsNotAVideo": audioIsNotAVideo,
            "plainControlNeedsTheNativePlayer": plainNeedsTheNativePlayer,
            "playingVideoWins": playingWins,
            "budgetIsShared": budgetIsShared,
            "windowsSearchedBeforeTheBudgetWasGone": searched,
            "elementsVisited": sharedBudget.visitedElements,
            "pausedOnce": pausedOnce,
            "pausedOnlyOnce": pausedOnlyOnce,
            "resumedOnce": resumedOnce,
            "resumedOnlyOnce": resumedOnlyOnce,
            "pausedVideoIsLeftAlone": pausedVideoIsLeftAlone,
            "replacedVideoIsNotResumed": replacedIsNotResumed,
            "vanishedTargetIsNotResumed": vanishedIsNotResumed,
            "userPlaybackIsLeftAlone": userPlaybackIsLeftAlone,
            "sameElementIsTheSame": sameElementIsTheSame,
        ]
        for (name, passed) in youtubeChecks() { checks[name] = passed }
        return checks
    }
}
