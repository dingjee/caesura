import AppKit
import SwiftUI
import CaesuraCore

/// The tooltip of the menu bar item.
///
/// The window of a status item belongs to the app, but the pointer over the
/// menu bar never reaches it: the system handles the menu bar and the app
/// hears neither the movement of the pointer nor its leaving. The tooltip of
/// the system therefore stays on the screen when the pointer moves to another
/// application, and every refresh of the menu bar item armed it again, which
/// let it jump to the current pointer position.
///
/// This tooltip belongs to the app: it watches where the pointer is, appears
/// after a moment of rest on the icon and disappears as soon as the pointer
/// leaves the icon, the app loses the focus or the menu opens.
final class StatusItemTooltip: NSObject {
    /// The interval of the check where the pointer is.
    static let pollInterval: TimeInterval = 0.2
    /// How long the pointer has to rest on the icon before the tooltip
    /// appears (the delay of the system tooltip).
    static let showDelay: TimeInterval = 0.6

    /// True while the tooltip is on the screen.
    private(set) var isVisible = false

    private weak var button: NSStatusBarButton?
    private let panel = StatusItemTooltipPanel()
    /// The check of the pointer position.
    private var timer: Timer?
    /// The pending appearance of the tooltip.
    private var pendingShow: Timer?
    /// True while the pointer rests on the icon.
    private var hovering = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            self?.checkPointer()
        }
        // The check has to run while a menu is open or a window is resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        pendingShow?.invalidate()
    }

    /// The text of the tooltip. It changes while the tooltip is on the screen
    /// (the time to the next break), so the bubble follows it.
    var text: String = "" {
        didSet {
            guard isVisible else { return }
            panel.present(text: text, anchor: anchorFrame())
        }
    }

    /// The icon the tooltip belongs to.
    func attach(to button: NSStatusBarButton) {
        self.button = button
    }

    /// The icon is gone: the tooltip is gone with it.
    func detach() {
        button = nil
        hovering = false
        hide()
    }

    // MARK: Pointer

    /// Looks where the pointer is and shows or hides the tooltip.
    ///
    /// The app cannot ask the system for the events of the menu bar, so the
    /// pointer is looked up instead: the answer is the same, no matter which
    /// application is in front.
    private func checkPointer() {
        let anchor = anchorFrame()
        guard anchor != .zero else {
            hovering = false
            hide()
            return
        }
        if anchor.contains(NSEvent.mouseLocation) {
            guard !hovering else { return }
            hovering = true
            scheduleShow()
        } else {
            hovering = false
            hide()
        }
    }

    /// Shows the tooltip after the delay — but only while the pointer still
    /// rests on the icon.
    private func scheduleShow() {
        pendingShow?.invalidate()
        pendingShow = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) {
            [weak self] _ in
            self?.show()
        }
    }

    private func show() {
        pendingShow = nil
        guard !isVisible else { return }
        let anchor = anchorFrame()
        guard anchor.contains(NSEvent.mouseLocation) else {
            // The pointer left the icon while the delay ran: the next check
            // starts over.
            hovering = false
            return
        }
        panel.present(text: text, anchor: anchor)
        isVisible = true
        Log.info("Caesura: the menu bar tooltip is shown")
    }

    /// Hides the tooltip. It goes away with the pointer, with the focus of the
    /// app and with the menu.
    func hide() {
        pendingShow?.invalidate()
        pendingShow = nil
        guard isVisible else { return }
        isVisible = false
        panel.dismiss()
        Log.info("Caesura: the menu bar tooltip is hidden")
    }

    @objc private func applicationDidResignActive() {
        hide()
    }

    /// The frame of the icon in the coordinates of the screen.
    ///
    /// The frame of the window is the anchor, not the conversion of the button:
    /// the window of a status item has its own base coordinate system, so the
    /// conversion lands at the origin of the screen instead of at the icon.
    private func anchorFrame() -> NSRect {
        guard let window = button?.window, window.isVisible else { return .zero }
        return window.frame
    }
}

/// The panel that carries the tooltip of the menu bar item.
final class StatusItemTooltipPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the windows of the applications, below the alerts of the system.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        // The tooltip never takes the pointer: it must not disturb the menu.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the tooltip under the icon.
    func present(text: String, anchor: NSRect) {
        let hosting = NSHostingView(rootView: StatusItemTooltipView(text: text))
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        hosting.frame = CGRect(origin: .zero, size: size)
        contentView = hosting

        // The bubble hangs under the icon and stays inside its screen.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let margin: CGFloat = 12
        var x = anchor.midX - size.width / 2
        if let screen {
            x = min(max(x, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
        }
        let gap: CGFloat = 6
        setFrame(NSRect(x: x, y: anchor.minY - size.height - gap,
                        width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    /// Takes the tooltip off the screen.
    func dismiss() {
        orderOut(nil)
    }
}

/// The bubble of the tooltip: the text of the menu bar item in a rounded
/// material bubble.
struct StatusItemTooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 320, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.28), radius: 10, y: 4)
            }
    }
}
