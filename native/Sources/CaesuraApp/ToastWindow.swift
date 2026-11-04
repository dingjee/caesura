import AppKit
import SwiftUI
import CaesuraCore

/// A short-lived toast under the menu bar item: it points at the icon and says
/// that Caesura is running. It is the whole first-run experience — the app
/// is a background app, so the toast never takes the focus, it fades away on
/// its own and a click dismisses it.
final class ToastWindow: NSPanel {
    private var dismissTimer: Timer?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, but never in front of the alerts of the system.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the toast below the menu bar icon and fades it out after a moment.
    func present(anchor: NSRect, duration: TimeInterval = 4.5) {
        guard let content = contentView else { return }
        // The panel is created without a size: the content decides it. The view
        // has to be laid out at that size, otherwise the drawing would be
        // squeezed into the (empty) frame of the panel.
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        content.frame = CGRect(origin: .zero, size: size)

        // The bubble hangs under the icon, its tail points at it. The bubble is
        // kept inside the screen of the icon.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let margin: CGFloat = 12
        var x = anchor.midX - size.width / 2
        if let screen {
            x = min(max(x, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
        }
        let gap: CGFloat = 6
        let y = anchor.minY - size.height - gap
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        alphaValue = 0
        orderFrontRegardless()
        Tween.appKit(TransitionTokens.smallFeedbackMillis, .entering) { _ in
            self.animator().alphaValue = 1
        }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Fades the toast out and closes the panel.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        Tween.appKit(TransitionTokens.smallFeedbackDismissMillis, .exiting, { _ in
            self.animator().alphaValue = 0
        }, completion: { [weak self] in
            self?.orderOut(nil)
            self?.close()
        })
    }
}

/// The bubble: a rounded shape with a small tail at the top that points at the
/// menu bar icon.
struct ToastBubble: InsettableShape {
    var cornerRadius: CGFloat = 14
    var tailWidth: CGFloat = 20
    var tailHeight: CGFloat = 9
    /// The inset of the border stroke (`strokeBorder` shrinks the shape).
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = min(insetAmount, rect.width / 4, rect.height / 4)
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = max(1, min(cornerRadius, box.width / 2, box.height / 2))
        let tailBase = box.minY + tailHeight
        let midX = box.midX
        // The body of the bubble.
        path.addRoundedRect(in: CGRect(x: box.minX, y: tailBase,
                                       width: box.width, height: box.maxY - tailBase),
                            cornerSize: CGSize(width: radius, height: radius),
                            style: .continuous)
        // The tail, pointing up at the icon.
        path.move(to: CGPoint(x: midX - tailWidth / 2, y: tailBase + radius * 0.5))
        path.addLine(to: CGPoint(x: midX, y: box.minY))
        path.addLine(to: CGPoint(x: midX + tailWidth / 2, y: tailBase + radius * 0.5))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> ToastBubble {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The content of the toast: the message and the bubble around it.
struct ToastView: View {
    var title: String
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .background {
            // The material is the glass of the bubble; the border would draw the
            // outline of the tail over the body, so only the shadow defines the
            // edge.
            ToastBubble()
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.24), radius: 14, y: 5)
        }
        .contentShape(ToastBubble())
        .onTapGesture(perform: onDismiss)
    }
}
