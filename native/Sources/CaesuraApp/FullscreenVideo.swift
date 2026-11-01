import AppKit
import ApplicationServices
import CaesuraCore

/// Detects a video that plays in fullscreen and pauses it during a break.
///
/// macOS offers no public way to ask another application whether it plays
/// media, and the media key is a blind toggle that reaches whatever holds the
/// media session — it may resume what the user had paused, and it may pause a
/// player that never showed a video. So this module only ever acts on a
/// playback it could **read**: the frontmost application that owns a window
/// covering a whole screen is asked, over the Accessibility interface, for a
/// control that carries the name "Pause" (the video plays) or "Play" (the
/// video is already paused) — read from **every** accessibility name the
/// control has (title, description and help), because the semantic name can
/// end up in any of the three and a non-semantic title must never shadow it
/// (`PlaybackNames` in CaesuraCore owns the names and the verdict). A video
/// that plays is paused by pressing that control, a paused
/// video is left alone, and a playback that cannot be read is left alone
/// too — the state stays unknown, never a guess.
///
/// Everything here is public API. Reading and pressing the control needs the
/// accessibility permission; without it nothing is sent and the app says so.
enum FullscreenVideo {
    /// The application in front that shows something in fullscreen.
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
    /// read, the very window and control that say it. The resume later only
    /// ever uses that same control — never a new search for a control that
    /// happens to be called "Play".
    struct Observation {
        let state: PlaybackState
        let window: AXUIElement?
        /// The control that names the state ("Pause" while it plays, "Play"
        /// while it is paused).
        let control: AXUIElement?
    }

    /// The bounds of one walk through the tree of a window. A browser with a
    /// huge tree must never be able to hold the scheduler: the walk counts the
    /// elements, the levels and the time, and every single call into another
    /// process gets its own short messaging timeout.
    private enum Walk {
        static let maximumDepth = 14
        static let maximumElements = 600
        static let maximumQueue = 400
        static let overallSeconds = 1.2
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

    /// The application that is in front and owns a window that covers a whole
    /// screen. The frontmost application is the one the user watches; a
    /// fullscreen window of an application in the background is not a video
    /// the user is following, and touching it would be a surprise.
    static func target() -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let ownName = ProcessInfo.processInfo.processName
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || front.bundleIdentifier == ownBundle
            || front.localizedName == ownName {
            return nil
        }
        guard ownsFullscreenWindow(processIdentifier: front.processIdentifier) else { return nil }
        return Target(bundleIdentifier: front.bundleIdentifier ?? "",
                      processIdentifier: front.processIdentifier,
                      name: front.localizedName ?? "")
    }

    /// Does the application with that process own a window of the size of a
    /// screen? The size is enough: a window in fullscreen has the size of the
    /// screen it is on.
    private static func ownsFullscreenWindow(processIdentifier: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            // Layer 0 are the normal windows; the panels of the system (the
            // menu bar, the Dock) live above them.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? Int,
                  pid_t(owner) == processIdentifier else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if coversScreen(rect) { return true }
        }
        return false
    }

    /// Does the window cover a whole screen?
    private static func coversScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            abs(rect.width - screen.frame.width) < 2 && abs(rect.height - screen.frame.height) < 2
        }
    }

    /// Reads the playback of a target: a control that stops the playback means
    /// it runs, a control that starts it means it is paused, and nothing means
    /// the state is unknown — only an exact name of a real button in the
    /// fullscreen window itself counts.
    static func observe(target: Target) -> Observation {
        guard canUseAccessibility else {
            return Observation(state: .unknown(reason: "the accessibility permission is missing"),
                               window: nil, control: nil)
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        guard let window = firstChild(of: application, attribute: kAXFocusedWindowAttribute)
            ?? firstChild(of: application, attribute: kAXMainWindowAttribute) else {
            return Observation(state: .unknown(reason: "the window of '\(target.name)' could not be read"),
                               window: nil, control: nil)
        }
        // The window that is read has to be the fullscreen window itself: the
        // same application may well show another window (a tab, a library)
        // while the video plays in a different one.
        guard isFullscreenWindow(window) else {
            return Observation(state: .unknown(reason: "the window of '\(target.name)' that is in front is "
                                                     + "not in fullscreen"),
                               window: nil, control: nil)
        }
        var pause: AXUIElement?
        var play: AXUIElement?
        searchControls(in: window) { element, names in
            switch PlaybackNames.classify(names) {
            case .pause:
                if pause == nil { pause = element }
            case .play:
                if play == nil { play = element }
            case nil:
                // No name matches, or the names contradict each other: the
                // control states nothing and is never pressed.
                break
            }
            return pause != nil && play != nil
        }
        if let pause {
            return Observation(state: .playing, window: window, control: pause)
        }
        if let play {
            return Observation(state: .paused, window: window, control: play)
        }
        return Observation(state: .unknown(reason: "no control that names the playback was found in the fullscreen "
                                                 + "window of '\(target.name)' (macOS offers no public way to ask "
                                                 + "an application whether it plays media)"),
                           window: window, control: nil)
    }

    /// Does the AX window have the size of a screen? A window in fullscreen
    /// has the size of the screen it is on.
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
    /// order. Empty when the element is gone, does not answer or is not a
    /// button with a name any more. All of the names count together — the
    /// verdict over them is `PlaybackNames.classify`.
    static func names(of control: AXUIElement) -> [String] {
        setTimeout(on: control)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(control, kAXRoleAttribute as CFString, &role) == .success,
              let roleValue = role as? String, roleValue == "AXButton" else { return [] }
        var names: [String] = []
        for attribute in nameAttributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(control, attribute as CFString, &value) == .success,
                  let text = value as? String, !text.isEmpty else { continue }
            if !names.contains(text) { names.append(text) }
        }
        return names
    }

    /// Presses a control that was read before and reports whether the press
    /// went through. The caller verifies the effect on the very same element.
    static func press(_ control: AXUIElement) -> Bool {
        setTimeout(on: control)
        return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
    }

    /// Reads every name of the pressed control again until they state the
    /// expected one, for at most a fifth of a second in steps of 20 ms — a
    /// press is not always reflected in the names on the very first read.
    /// Only the very element that was pressed is read: no new search, no
    /// toggle.
    static func confirmedName(of control: AXUIElement,
                              expected: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(0.2)
        while true {
            let names = names(of: control)
            if !names.isEmpty, expected(names) { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }

    /// The one child behind an attribute of an element (`kAXFocusedWindowAttribute`…).
    private static func firstChild(of element: AXUIElement, attribute: String) -> AXUIElement? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement?)
    }

    /// A short timeout for every call that goes through the element.
    private static func setTimeout(on element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, Walk.elementTimeout)
    }

    /// Walks the tree of the window and hands every pressable button with a
    /// name, together with all of its names, to `visit`. The walk is bounded
    /// in depth, in elements, in queue length and in time, and it checks the
    /// bounds **per element and per call** — a single wide level of a large
    /// browser tree must never run for seconds on its own.
    private static func searchControls(in window: AXUIElement,
                                       visit: (AXUIElement, [String]) -> Bool) {
        var queue: [AXUIElement] = [window]
        var nextLevel: [AXUIElement] = []
        var depth = 0
        var visited = 0
        let deadline = Date().addingTimeInterval(Walk.overallSeconds)
        var expired = false
        func outOfBudget() -> Bool {
            if expired { return true }
            if depth > Walk.maximumDepth || visited >= Walk.maximumElements || Date() > deadline {
                expired = true
                return true
            }
            return false
        }
        while !queue.isEmpty, !expired {
            for element in queue {
                if outOfBudget() { return }
                visited += 1
                setTimeout(on: element)
                let names = names(of: element)
                if !names.isEmpty {
                    if visit(element, names) { return }
                }
                if outOfBudget() { return }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                                    &children) == .success,
                      let list = children as? [AXUIElement] else { continue }
                nextLevel.append(contentsOf: list.prefix(Walk.maximumQueue - nextLevel.count))
                if nextLevel.count >= Walk.maximumQueue { nextLevel.removeLast(nextLevel.count - Walk.maximumQueue) }
            }
            queue = nextLevel
            nextLevel = []
            depth += 1
        }
    }
}

/// The pause of the video of a break: it finds the target, reads its state,
/// pauses a playing video and resumes exactly the playback it paused — through
/// the very same control, never through a new search.
///
/// The controller keeps the window and the control of the paused playback; the
/// resume touches nothing else. A video the user started again stays playing,
/// a control that is gone or stale ends the attempt, and a state that cannot
/// be read is never toggled.
final class FullscreenVideoController {
    /// The playback that was paused for the running break, with the very
    /// window and control that were read.
    private struct PausedPlayback {
        let target: FullscreenVideo.Target
        let window: AXUIElement
        let control: AXUIElement
    }

    /// The playback that was paused for the running break.
    private var paused: PausedPlayback?

    /// True when the playback of this break was paused and confirmed.
    var didPause: Bool { paused != nil }

    /// Pauses the video of the frontmost fullscreen application, so that the
    /// break does not talk over it. Runs once per break: a second call while a
    /// pause is already remembered does nothing. A paused video is left
    /// alone, an unreadable state is left alone, and only a confirmed pause is
    /// remembered for the resume.
    func pauseIfNeeded() {
        guard paused == nil else { return }
        guard let target = FullscreenVideo.target() else { return }
        let observation = FullscreenVideo.observe(target: target)
        switch observation.state {
        case .paused:
            Log.info("Caesura: the video of '\(target.name)' in fullscreen is paused already, nothing to do")
        case .unknown(let reason):
            Log.info("Caesura: the playback of '\(target.name)' in fullscreen stays untouched — \(reason)")
        case .playing:
            guard let control = observation.control else { return }
            guard FullscreenVideo.press(control) else {
                Log.warn("Caesura: the 'Pause' control of '\(target.name)' could not be pressed")
                return
            }
            // The very same element tells whether the press went through: its
            // names flip from "Pause" to "Play", within a short bounded wait.
            guard FullscreenVideo.confirmedName(of: control,
                                                expected: { PlaybackNames.classify($0) == .play }) else {
                Log.warn("Caesura: the video of '\(target.name)' did not report the pause, "
                         + "nothing is remembered for the resume")
                return
            }
            paused = PausedPlayback(target: target,
                                    window: observation.window ?? control,
                                    control: control)
            Log.info("Caesura: paused the video of '\(target.name)' in fullscreen for the break")
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
        // The window has to answer and to still be the fullscreen window: a
        // closed window or tab leaves a stale element, a window that is not in
        // fullscreen any more is not the video that was paused.
        guard FullscreenVideo.isFullscreenWindow(paused.window),
              let windowTitle = windowTitle(of: paused.window) else {
            Log.info("Caesura: the fullscreen window of '\(target.name)' that was paused for the break is gone, nothing to resume")
            return
        }
        _ = windowTitle
        // The control has to answer and to state "Play" — through every name
        // it carries, so a non-semantic title cannot hide the state anything
        // else — and to state nothing else: anything different means the
        // state changed while the break ran, and it is not touched.
        let names = FullscreenVideo.names(of: paused.control)
        guard !names.isEmpty else {
            Log.info("Caesura: the control of the paused video of '\(target.name)' is gone, nothing to resume")
            return
        }
        guard PlaybackNames.classify(names) == .play else {
            Log.info("Caesura: the video of '\(target.name)' reports '\(names.joined(separator: "', '"))' "
                     + "and is not resumed a second time")
            return
        }
        guard FullscreenVideo.press(paused.control) else {
            Log.warn("Caesura: the play control of '\(target.name)' could not be pressed")
            return
        }
        if FullscreenVideo.confirmedName(of: paused.control,
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

    /// The title of the window, read to learn whether the element still lives.
    private func windowTitle(of window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }
}
