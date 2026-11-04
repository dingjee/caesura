import AppKit
import ApplicationServices
import CaesuraCore

/// One element of the accessibility tree of another application.
///
/// The real implementation reads another process over the Accessibility
/// interface; the offscreen probe walks an in-memory tree, so the rules of
/// the search can be checked without any other application and without
/// touching a real player.
protocol AccessibilityElement: AnyObject {
    /// The role of the element ("AXButton", "AXGroup", …).
    var role: String? { get }
    /// The subrole of the element ("AXVideo" for a video element).
    var subrole: String? { get }
    /// Every accessibility name the element carries (title, description and
    /// help).
    var names: [String] { get }
    /// True when the element supports the press action.
    var supportsPress: Bool { get }
    /// The children of the element.
    var children: [any AccessibilityElement] { get }
    /// The parent of the element.
    var parent: (any AccessibilityElement)? { get }
    /// The window the element belongs to.
    var window: (any AccessibilityElement)? { get }
    /// The address of the media the element shows, when it has one.
    var url: String? { get }
    /// The title of the element (a window has one).
    var title: String? { get }
    /// The process the element belongs to.
    var processIdentifier: pid_t { get }
    /// True when the element is a window that covers a whole screen.
    var isFullscreenWindow: Bool { get }
    /// Presses the element — the play/pause control.
    func press() -> Bool
    /// True when the other element is the very same element.
    ///
    /// The elements of another process are compared by their identity, not
    /// by the object that carries them: two wrappers around one
    /// accessibility element are the same element.
    func isSameElement(as other: any AccessibilityElement) -> Bool
}

/// Detects a video that plays and pauses it during a break.
///
/// macOS offers no public way to ask another application whether it plays
/// media, and the media key is a blind toggle that reaches whatever holds the
/// media session — it may resume what the user had paused, and it may pause a
/// player that never showed a video. So this module only ever acts on a
/// playback it could **read**: over the Accessibility interface it looks for
/// a control that carries the name "Pause" (the video plays) or "Play" (the
/// video is already paused) — read from **every** accessibility name the
/// control has (title, description and help), because the semantic name can
/// end up in any of the three and a non-semantic title must never shadow it
/// (`PlaybackNames` in CaesuraCore owns the names and the verdict).
///
/// Where the control has to sit:
///
/// - In a window **in the normal size** it only counts when it sits inside a
///   **video element** — an accessibility element with the subrole `AXVideo`,
///   which is the HTML-AAM mapping of the `<video>` element (an `<audio>`
///   element carries the subrole `AXAudio` and is never matched, so an audio
///   playback is never mistaken for a video). The localised role description
///   is never used to decide this: only the subrole counts.
/// - In a window **in fullscreen** the control of a **known native video
///   player** may be acted on even outside a video element. A browser in
///   fullscreen is not such a player: it has to show a video element too.
///
/// A video that plays is paused by pressing that control, a paused video is
/// left alone, and a playback that cannot be read is left alone too — the
/// state stays unknown, never a guess.
///
/// Everything here is public API. Reading and pressing the control needs the
/// accessibility permission; without it nothing is sent and the app says so.
enum VideoPlayback {
    /// The application in front that shows something.
    struct Target: Equatable {
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let name: String
    }

    /// What the target plays, as far as the public interfaces can tell.
    enum PlaybackState: Equatable {
        /// A control that stops the playback is there.
        case playing
        /// A control that starts the playback is there.
        case paused
        /// Nothing told: no control found, or no permission. Never a guess.
        case unknown(reason: String)
    }

    /// One read of the playback of a target: the state and, when it could be
    /// read, the very window, the video element and the control that say it.
    /// The resume later only ever uses that same control — never a new search
    /// for a control that happens to be called "Play".
    struct Observation {
        let state: PlaybackState
        let window: (any AccessibilityElement)?
        /// The video element the control belongs to; nil for a native player
        /// that shows its control outside a video element.
        let container: (any AccessibilityElement)?
        /// The control that names the state ("Pause" while it plays, "Play"
        /// while it is paused).
        let control: (any AccessibilityElement)?
    }

    /// What one search found.
    struct Search {
        /// The control that names the playback.
        let control: (any AccessibilityElement)?
        /// The video element the control sits in.
        let container: (any AccessibilityElement)?
        /// What the control says: nil when nothing was found.
        let verdict: PlaybackNames.Verdict?
        /// True when the search was cut short by the budget.
        var exhausted = false
    }

    /// One element of the walk, with the video element it sits in (nil when
    /// it is not inside one).
    private struct Node {
        let element: any AccessibilityElement
        let container: (any AccessibilityElement)?
    }

    /// The bounds of one search. The whole search shares them: the windows of
    /// the application and their subtrees alike, so a page with many windows
    /// and many videos can never hold the scheduler.
    private enum Walk {
        static let overallSeconds = 1.0
        static let maximumElements = 2_500
        static let maximumDepth = 40
        static let maximumQueue = 1_200
        /// The timeout of one attribute read or action of one element.
        static let elementTimeout: Float = 0.05
        /// The tolerance of the comparison with the size of a screen.
        static let boundsTolerance: CGFloat = 2
    }

    /// The accessibility name attributes of a control, in the order they are
    /// read. All of them count — the semantic name ("Pause (k)", "Play (k)")
    /// of a web player can end up in the title, the description or the help
    /// text, and a non-semantic title (a video or page title) must never
    /// shadow a meaningful description, so no "first non-empty wins" happens
    /// here.
    private static let nameAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]

    /// The roles that can carry a pressable control. The native players and
    /// the web players both expose their play/pause control as a button.
    private static let controlRoles: Set<String> = ["AXButton"]

    /// The role of a video element (the HTML-AAM mapping of `<video>`).
    private static let groupRole = "AXGroup"

    /// The known native video players. Only for them a control outside a
    /// video element may be acted on, and only in a window in fullscreen:
    /// everywhere else a control has to sit inside a video element.
    static let nativePlayerBundleIdentifiers: Set<String> = [
        "org.videolan.vlc",
        "com.colliderli.iina",
        // The bundle identity of QuickTime Player on this system (read from
        // its own Info.plist): "com.apple.QuickTimePlayerX".
        "com.apple.QuickTimePlayerX",
    ]

    /// True when the app may read and press the controls of other applications.
    static var canUseAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS for the accessibility permission. Only ever called from the
    /// preferences, on a click of the user — the app never asks on its own and
    /// never opens the system settings by itself.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The application in front: the one the user watches. A video of an
    /// application in the background is not a video the user is following, and
    /// touching it would be a surprise.
    static func target() -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let ownName = ProcessInfo.processInfo.processName
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || front.bundleIdentifier == ownBundle
            || front.localizedName == ownName {
            return nil
        }
        return Target(bundleIdentifier: front.bundleIdentifier ?? "",
                      processIdentifier: front.processIdentifier,
                      name: front.localizedName ?? "")
    }

    /// Reads the playback of a target: a control that stops the playback means
    /// it runs, a control that starts it means it is paused, and nothing means
    /// the state is unknown.
    static func observe(target: Target) -> Observation {
        guard canUseAccessibility else {
            return Observation(state: .unknown(reason: "the accessibility permission is missing"),
                               window: nil, container: nil, control: nil)
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        let windows = candidateWindows(of: application)
        guard !windows.isEmpty else {
            return Observation(state: .unknown(reason: "no window of '\(target.name)' could be read"),
                               window: nil, container: nil, control: nil)
        }
        let budget = TreeBudget(seconds: Walk.overallSeconds,
                                maximumElements: Walk.maximumElements,
                                maximumDepth: Walk.maximumDepth,
                                maximumQueue: Walk.maximumQueue)
        let nativePlayer = nativePlayerBundleIdentifiers.contains(target.bundleIdentifier)
        var playing: Search?
        var paused: Search?
        var window: AXUIElement?
        var exhausted = false
        // The windows are read in the order of the candidates (the focused
        // one, the main one, then the rest). A playback that runs is
        // decisive; a paused one never stops the search — it must not hide a
        // video that plays.
        for candidate in windows {
            let element = AXElement(candidate)
            let allowOutsideVideo = nativePlayer && element.isFullscreenWindow
            let result = search(in: element, budget: budget, allowOutsideVideo: allowOutsideVideo)
            exhausted = exhausted || result.exhausted
            // The budget is gone: no further window is read at all.
            if budget.isExhausted { break }
            if result.verdict == .pause, playing == nil {
                playing = result
                window = candidate
                break
            }
            if result.verdict == .play, paused == nil {
                paused = result
                window = candidate
            }
        }
        if let playing {
            return Observation(state: .playing, window: window.map { AXElement($0) },
                               container: playing.container, control: playing.control)
        }
        if let paused {
            return Observation(state: .paused, window: window.map { AXElement($0) },
                               container: paused.container, control: paused.control)
        }
        let reason = exhausted
            ? "the search through the windows of '\(target.name)' was cut short after "
                + "\(budget.visitedElements) elements (macOS offers no public way to ask an application "
                + "whether it plays media)"
            : "no control that names the playback was found in a window of '\(target.name)' "
                + "(macOS offers no public way to ask an application whether it plays media)"
        return Observation(state: .unknown(reason: reason), window: nil, container: nil, control: nil)
    }

    /// Searches one window for a control that names the playback.
    ///
    /// One traversal and one budget: the elements inside a video element are
    /// marked with it while the walk goes on, so the control of a video is
    /// found in the same walk that finds the video element — never in a
    /// second, separately timed walk.
    ///
    /// `allowOutsideVideo` is true only for a known native video player in a
    /// window in fullscreen: everywhere else a control only counts when it
    /// sits inside a video element.
    static func search(in window: any AccessibilityElement,
                       budget: TreeBudget,
                       allowOutsideVideo: Bool) -> Search {
        var found = Search(control: nil, container: nil, verdict: nil)
        var queue: [Node] = [Node(element: window, container: nil)]
        var depth = 0
        while !queue.isEmpty {
            if depth > budget.maximumDepth { break }
            var next: [Node] = []
            for node in queue {
                guard budget.spend() else {
                    found.exhausted = true
                    return found
                }
                let role = node.element.role
                // A control that names the playback: the verdict is read
                // once, never guessed.
                if controlRoles.contains(role ?? "") {
                    let names = node.element.names
                    if !names.isEmpty,
                       let verdict = PlaybackNames.classify(names),
                       node.element.supportsPress {
                        let insideVideo = node.container != nil
                        if insideVideo || allowOutsideVideo {
                            if verdict == .pause {
                                // A playback that runs is decisive.
                                return Search(control: node.element, container: node.container,
                                              verdict: verdict)
                            }
                            if found.verdict == nil {
                                found = Search(control: node.element, container: node.container,
                                               verdict: verdict)
                            }
                        }
                    }
                }
                // The children of a video element are inside it.
                let container = (role == groupRole
                                 && VideoPlaybackRules.isVideoSubrole(node.element.subrole))
                    ? node.element : node.container
                for child in node.element.children {
                    // The whole level is bounded, not every parent of it.
                    guard next.count < budget.maximumQueue else { break }
                    next.append(Node(element: child, container: container))
                }
            }
            queue = next
            depth += 1
        }
        found.exhausted = found.exhausted || budget.isExhausted
        return found
    }

    /// May the playback that was paused be resumed?
    ///
    /// Only the very same control of the very same video element, with the
    /// very same media: a page that navigated away, a video that was replaced
    /// and a control that is gone end the attempt — nothing else is ever
    /// searched or pressed.
    static func mayResume(_ control: any AccessibilityElement,
                           container: (any AccessibilityElement)?,
                           containerURL: String?,
                           window: (any AccessibilityElement)?,
                           processIdentifier: pid_t) -> Bool {
        // The control has to answer and to state "Play".
        guard let verdict = verdict(of: control), verdict == .play else { return false }
        // The control has to belong to the same process and to the same
        // window it was read from.
        guard control.processIdentifier == processIdentifier else { return false }
        guard belongsToWindow(control, window) else { return false }
        // A native player shows its control outside a video element: the
        // control itself is the target then.
        guard let container else { return true }
        // The video element has to be there, and the control has to belong to
        // it: a control of another element is never pressed.
        guard VideoPlaybackRules.isVideoSubrole(container.subrole) else { return false }
        guard belongsTo(control, container) else { return false }
        // The video element has to belong to the same process and window too.
        guard container.processIdentifier == processIdentifier else { return false }
        guard belongsToWindow(container, window) else { return false }
        // The media has to be the same one. A recorded address that is gone
        // now is a video that was replaced, not the video that was paused.
        if let recorded = containerURL {
            guard let current = container.url, current == recorded else { return false }
        }
        return true
    }

    /// Does the element belong to the window?
    ///
    /// The window of the element is the proof. When the element does not name
    /// one, the bounded parent chain has to reach the window — and a chain
    /// that does not reach it refuses: an unknown target is never acted on.
    private static func belongsToWindow(_ element: any AccessibilityElement,
                                        _ window: (any AccessibilityElement)?) -> Bool {
        guard let window else { return false }
        if let own = element.window { return own.isSameElement(as: window) }
        var current: (any AccessibilityElement)? = element
        var depth = 0
        while let candidate = current, depth < 64 {
            if candidate.isSameElement(as: window) { return true }
            current = candidate.parent
            depth += 1
        }
        return false
    }

    /// Is the element inside the ancestor? The parent chain is the proof that
    /// a control still belongs to the video element it was read from.
    static func belongsTo(_ element: any AccessibilityElement,
                           _ ancestor: any AccessibilityElement) -> Bool {
        var current: (any AccessibilityElement)? = element
        var depth = 0
        while let candidate = current, depth < 64 {
            if candidate.isSameElement(as: ancestor) { return true }
            current = candidate.parent
            depth += 1
        }
        return false
    }

    /// The verdict of an element, read once: what its names say about the
    /// playback — nil when the element is no control, carries no name, states
    /// nothing or cannot be pressed.
    static func verdict(of element: any AccessibilityElement) -> PlaybackNames.Verdict? {
        guard controlRoles.contains(element.role ?? "") else { return nil }
        let names = element.names
        guard !names.isEmpty else { return nil }
        guard let verdict = PlaybackNames.classify(names) else { return nil }
        guard element.supportsPress else { return nil }
        return verdict
    }

    /// Reads every name of the pressed control again until they state the
    /// expected one, for at most a fifth of a second in steps of 20 ms — a
    /// press is not always reflected in the names on the very first read.
    /// Only the very element that was pressed is read: no new search, no
    /// toggle.
    static func confirmedName(of control: any AccessibilityElement,
                              expected: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(0.2)
        while true {
            let names = control.names
            if !names.isEmpty, expected(names) { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }

    /// The windows of the target that could show the video: the focused
    /// window first, then the main window, then every other window of the
    /// application. A browser may well show the video in a window that is
    /// neither the focused nor the main one — and the focused window of a
    /// browser is often not the tab with the video.
    static func candidateWindows(of application: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func append(_ element: AXUIElement?) {
            guard let element else { return }
            for existing in result where CFEqual(existing, element) { return }
            result.append(element)
        }
        append(firstChild(of: application, attribute: kAXFocusedWindowAttribute))
        append(firstChild(of: application, attribute: kAXMainWindowAttribute))
        for window in children(of: application, attribute: kAXWindowsAttribute) {
            append(window)
        }
        return result
    }

    // MARK: - The accessibility interface

    /// The AX implementation of an accessibility element.
    final class AXElement: AccessibilityElement {
        let element: AXUIElement

        init(_ element: AXUIElement) {
            self.element = element
        }

        var role: String? { VideoPlayback.string(of: element, attribute: kAXRoleAttribute) }
        var subrole: String? { VideoPlayback.string(of: element, attribute: kAXSubroleAttribute) }
        var names: [String] { VideoPlayback.names(of: element) }
        var supportsPress: Bool { VideoPlayback.supportsPress(element) }
        var children: [any AccessibilityElement] {
            // The list is bounded: a wide level of a huge tree must not be
            // read into memory at once.
            VideoPlayback.children(of: element, attribute: kAXChildrenAttribute, limit: 1_200)
                .map { AXElement($0) }
        }
        var parent: (any AccessibilityElement)? {
            VideoPlayback.firstChild(of: element, attribute: kAXParentAttribute).map { AXElement($0) }
        }
        var window: (any AccessibilityElement)? {
            VideoPlayback.firstChild(of: element, attribute: kAXWindowAttribute).map { AXElement($0) }
        }
        var url: String? { VideoPlayback.url(of: element) }
        var title: String? { VideoPlayback.string(of: element, attribute: kAXTitleAttribute) }
        var processIdentifier: pid_t {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return 0 }
            return pid
        }
        var isFullscreenWindow: Bool { VideoPlayback.isFullscreenWindow(element) }
        func press() -> Bool { VideoPlayback.press(element) }
        /// The identity of an accessibility element: the same element of the
        /// other process, whoever carries it.
        func isSameElement(as other: any AccessibilityElement) -> Bool {
            guard let other = other as? AXElement else { return false }
            return CFEqual(element, other.element)
        }
    }

    /// Does the AX window have the size of a screen? A window in fullscreen
    /// has the size of the screen it is on.
    ///
    /// The size is the public evidence: macOS publishes no `AXFullScreen`
    /// attribute in its accessibility constants (only the fullscreen *button*
    /// of a window), so a window that covers a whole screen is what tells a
    /// player window from a normal one.
    static func isFullscreenWindow(_ window: AXUIElement) -> Bool {
        setTimeout(on: window)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success else {
            return false
        }
        let sizeValue = value as! AXValue
        guard AXValueGetType(sizeValue) == .cgSize else { return false }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else { return false }
        return NSScreen.screens.contains { screen in
            abs(size.width - screen.frame.width) < Walk.boundsTolerance
                && abs(size.height - screen.frame.height) < Walk.boundsTolerance
        }
    }

    /// Every accessibility name of a control, read with a short timeout: the
    /// title, the description and the help text, deduplicated, in attribute
    /// order.
    static func names(of control: AXUIElement) -> [String] {
        var names: [String] = []
        for attribute in nameAttributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(control, attribute as CFString, &value) == .success,
                  let text = value as? String, !text.isEmpty else { continue }
            if !names.contains(text) { names.append(text) }
        }
        return names
    }

    /// Does the element support the press action? A control that cannot be
    /// pressed is never pressed. The supported actions are the public
    /// `AXUIElementCopyActionNames` — the raw `AXActions` attribute is not
    /// part of the published accessibility constants.
    static func supportsPress(_ element: AXUIElement) -> Bool {
        setTimeout(on: element)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    /// Presses a control that was read before and reports whether the press
    /// went through. The caller verifies the effect on the very same element.
    static func press(_ control: AXUIElement) -> Bool {
        setTimeout(on: control)
        return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
    }

    /// The one child behind an attribute of an element (`kAXFocusedWindowAttribute`…).
    static func firstChild(of element: AXUIElement, attribute: String) -> AXUIElement? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement?)
    }

    /// The children of an element (the windows of an application…), bounded
    /// by `limit`.
    static func children(of element: AXUIElement, attribute: String,
                         limit: Int = Int.max) -> [AXUIElement] {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        guard limit < list.count else { return list }
        return Array(list.prefix(limit))
    }

    /// A string attribute of an element, read with a short timeout.
    static func string(of element: AXUIElement, attribute: String) -> String? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// The address of the media of an element. The accessibility interface
    /// answers with a URL, not with a string.
    static func url(of element: AXUIElement) -> String? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let address = value else { return nil }
        if let url = address as? URL { return url.absoluteString }
        if let url = address as? NSURL { return url.absoluteString }
        if let text = address as? String { return text }
        return nil
    }

    /// A short timeout for every call that goes through the element.
    static func setTimeout(on element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, Walk.elementTimeout)
    }
}

/// The pause of the video of a break: it finds the target, reads its state,
/// pauses a playing video and resumes exactly the playback it paused — through
/// the very same control, never through a new search.
///
/// The controller keeps the window, the video element and the control of the
/// paused playback; the resume touches nothing else. A video the user started
/// again stays playing, a control that is gone or stale ends the attempt, and
/// a state that cannot be read is never toggled.
final class VideoPlaybackController {
    /// The playback that was paused for the running break, with the very
    /// window, video element and control that were read.
    private struct PausedPlayback {
        let target: VideoPlayback.Target
        let window: any AccessibilityElement
        let container: (any AccessibilityElement)?
        /// The address of the media, when the video element had one: a video
        /// that was replaced is not the video that was paused.
        let containerURL: String?
        let control: any AccessibilityElement
        /// True when the video was found in a window in fullscreen.
        let fullscreen: Bool
    }

    /// The playback that was paused for the running break.
    private var paused: PausedPlayback?

    /// The target of the search: the application in front. The offscreen
    /// probe injects its own, so the real controller can be driven without
    /// another application.
    var targetProvider: () -> VideoPlayback.Target? = { VideoPlayback.target() }

    /// The read of the playback of the target. The offscreen probe injects
    /// its own.
    var observer: (VideoPlayback.Target) -> VideoPlayback.Observation = { VideoPlayback.observe(target: $0) }

    /// True when the playback of this break was paused and confirmed.
    var didPause: Bool { paused != nil }

    /// Pauses the video of the frontmost application, so that the break does
    /// not talk over it. Runs once per break: a second call while a pause is
    /// already remembered does nothing. A paused video is left alone, an
    /// unreadable state is left alone, and only a confirmed pause is
    /// remembered for the resume.
    func pauseIfNeeded() {
        guard paused == nil else { return }
        guard let target = targetProvider() else { return }
        let observation = observer(target)
        switch observation.state {
        case .paused:
            Log.info("Caesura: the video of '\(target.name)' is paused already, nothing to do")
        case .unknown(let reason):
            Log.info("Caesura: the playback of '\(target.name)' stays untouched — \(reason)")
        case .playing:
            guard let control = observation.control else { return }
            // The identity of the video and the address of its media are
            // collected BEFORE the press: the resume has to know what it
            // paused, and a video that is replaced in between is a different
            // one.
            let container = observation.container
            let containerURL = container?.url
            let window = observation.window ?? control
            let fullscreen = window.isFullscreenWindow
            // The control has to say "Pause" again right now: an observation
            // that is already stale is never acted on.
            guard VideoPlayback.verdict(of: control) == .pause else {
                Log.warn("Caesura: the control of '\(target.name)' does not say that the video plays "
                         + "any more, nothing is pressed")
                return
            }
            guard control.press() else {
                Log.warn("Caesura: the 'Pause' control of '\(target.name)' could not be pressed")
                return
            }
            // The very same element tells whether the press went through: its
            // names flip from "Pause" to "Play", within a short bounded wait.
            guard VideoPlayback.confirmedName(of: control,
                                                expected: { PlaybackNames.classify($0) == .play }) else {
                Log.warn("Caesura: the video of '\(target.name)' did not report the pause, "
                         + "nothing is remembered for the resume")
                return
            }
            paused = PausedPlayback(target: target,
                                    window: window,
                                    container: container,
                                    containerURL: containerURL,
                                    control: control,
                                    fullscreen: fullscreen)
            Log.info("Caesura: paused the video of '\(target.name)' for the break")
        }
    }

    /// Resumes the video that was paused for the break — through the very same
    /// control, and only while that control still says "Play". A video the
    /// user started again stays playing, a control that is gone or no longer
    /// answers ends the attempt, and nothing else is ever searched or pressed.
    func resumeIfNeeded() {
        guard let paused else { return }
        self.paused = nil
        let target = paused.target
        // The window has to answer and to be the same window of the same
        // process: a closed window or tab leaves a stale element, and another
        // process is another video.
        guard paused.window.title != nil else {
            Log.info("Caesura: the window of '\(target.name)' that was paused for the break is gone, nothing to resume")
            return
        }
        guard paused.window.processIdentifier == target.processIdentifier else {
            Log.info("Caesura: the window of '\(target.name)' belongs to another process now, nothing to resume")
            return
        }
        if paused.fullscreen, !paused.window.isFullscreenWindow {
            Log.info("Caesura: the window of '\(target.name)' is not in fullscreen any more, nothing to resume")
            return
        }
        // The very same control of the very same video element, with the very
        // same media.
        guard VideoPlayback.mayResume(paused.control,
                                      container: paused.container,
                                      containerURL: paused.containerURL,
                                      window: paused.window,
                                      processIdentifier: target.processIdentifier) else {
            Log.info("Caesura: the video of '\(target.name)' is not the one that was paused, nothing to resume")
            return
        }
        guard paused.control.press() else {
            Log.warn("Caesura: the play control of '\(target.name)' could not be pressed")
            return
        }
        if VideoPlayback.confirmedName(of: paused.control,
                                         expected: { PlaybackNames.classify($0) == .pause }) {
            Log.info("Caesura: resumed the video of '\(target.name)' after the break")
        } else {
            Log.warn("Caesura: the video of '\(target.name)' did not report the resume after the break")
        }
    }

    /// The break is over without a resume (the app quits): the video stays
    /// paused, the state is written down, nothing is toggled.
    func forget() {
        if let paused {
            Log.info("Caesura: the video of '\(paused.target.name)' paused for the break is left as it is")
        }
        self.paused = nil
    }
}
