import AppKit
import SwiftUI
import CaesuraCore

/// The measurement of a poem body.
///
/// The window measures the body with CoreText: the measured height decides
/// whether the body needs a scroll (a SwiftUI `Text` does not report its
/// wrapped height).
enum PoemBodyMetrics {
    /// The height of the wrapped text at the given face.
    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 0 else { return 0 }
        let rect = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(rect.height)
    }

    /// The height of every block of the body, wrapped at the given width.
    static func heights(of blocks: [NSAttributedString], width: CGFloat) -> [CGFloat] {
        blocks.map { height(of: $0, width: width) }
    }

    /// The height of the blocks of the body, with the spacing of the stack
    /// between them.
    static func height(of blocks: [NSAttributedString], spacing: CGFloat,
                       width: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        let heights = blocks.map { height(of: $0, width: width) }
        return heights.reduce(0, +) + spacing * CGFloat(blocks.count - 1)
    }
}

/// The layout of a poem body: the size of the type and the height of the body.
struct PoemBodyLayout {
    /// The size of the type.
    let fontSize: CGFloat
    /// The height of the whole body.
    let contentHeight: CGFloat
    /// The wrapped height of every line of the body.
    let lineHeights: [CGFloat]
    /// True when the body does not fit into the area it is drawn in.
    let overflows: Bool
}

/// The size of a poem body.
///
/// The body is drawn at the size of the type scale — the comfortable size the
/// display gives it. A longer body is never drawn with a smaller type: it
/// becomes a longer scroll in the reading viewport (see `PoemReadingViewport`).
enum PoemBodyLayoutResolver {
    /// The room the measurement keeps free: the wrapped height of a text and
    /// the height SwiftUI gives it may differ a little.
    private static let slack: CGFloat = 2

    /// The layout of a body of the given lines at its natural size.
    static func natural(lines: [String], natural: CGFloat, width: CGFloat, height: CGFloat,
                        spacing: CGFloat, font: @escaping (CGFloat) -> NSFont) -> PoemBodyLayout {
        let key = Key(text: lines.joined(separator: "\n"),
                      width: Int(width.rounded()), height: Int(height.rounded()),
                      natural: Int(natural.rounded()))
        return cache.layout(for: key) {
            let blocks = lines.map {
                NSAttributedString(string: $0, attributes: [.font: font(natural)])
            }
            let lineHeights = PoemBodyMetrics.heights(of: blocks, width: width)
            let measured = lineHeights.reduce(0, +) + spacing * CGFloat(max(0, blocks.count - 1))
            let contentHeight = measured + slack
            return PoemBodyLayout(fontSize: natural, contentHeight: contentHeight,
                                  lineHeights: lineHeights,
                                  overflows: contentHeight > height)
        }
    }

    private struct Key: Hashable {
        let text: String
        let width: Int
        let height: Int
        let natural: Int
    }

    private static let cache = PoemBodyLayoutCache()
}

/// The measured layouts of the bodies.
///
/// The window measures its body again on every tick of the break, so the
/// measurement is kept: the body of a break does not change while it is shown.
final class PoemBodyLayoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AnyHashable: PoemBodyLayout] = [:]
    private var order: [AnyHashable] = []
    private let limit = 8

    func layout(for key: AnyHashable, measure: () -> PoemBodyLayout) -> PoemBodyLayout {
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let layout = measure()
        lock.lock()
        entries[key] = layout
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return layout
    }
}

extension PoemBodyLayout {
    /// The y of the centre of every line, in the coordinates of the document
    /// (the body laid out in a stack with the given spacing).
    func lineCenters(spacing: CGFloat) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for height in lineHeights {
            centers.append(top + height / 2)
            top += height + spacing
        }
        return centers
    }
}

/// The dynamic emphasis rules of the reading focus: they follow the reading
/// state (the follow or the review, the accessibility settings) and are
/// published into the controller, so the hosted poem reads them live — the
/// identity of the poem and its scroll position are never touched.
struct PoemFocusEmphasis: Equatable {
    /// True while the viewport follows the poem (false while the reader
    /// reviews earlier lines): only then the new-word lines keep their
    /// secondary emphasis and the handover animates.
    let following: Bool
    /// True when the system asks for more contrast.
    let increaseContrast: Bool
    /// True when the system asks for less movement.
    let reduceMotion: Bool
    /// The brightness the lines with new words keep at least (nil: no boost).
    let boostedLineOpacity: Double?
    /// The lines that hold new words of this break (the frontier excluded).
    let boostedLines: Set<Int>
}

/// The reading focus shared between the scroll bridge and the poem lines.
///
/// The bridge reports where the reading anchor points (in the coordinates of
/// the document) every time the viewport settles on the main run loop; the
/// lines read it and derive their brightness from it, together with the
/// emphasis rules. Nothing publishes during a view update — the report is
/// always one merged run loop pass later, like the hover sync.
final class PoemFocusController: ObservableObject {
    /// The y of the reading anchor in the coordinates of the document.
    @Published var anchorY: CGFloat = 0
    /// The emphasis rules of the focus (see `PoemFocusEmphasis`).
    @Published var emphasis = PoemFocusEmphasis(following: true, increaseContrast: false,
                                                reduceMotion: false,
                                                boostedLineOpacity: nil, boostedLines: [])
}

/// The fade at the top of a reading viewport: content that has moved past the
/// top melts away instead of ending in the middle of a letter.
struct PoemTopFade: View {
    /// The height of the viewport the fade sits in.
    let height: CGFloat

    var body: some View {
        let fade = min(height * 0.16, 26)
        LinearGradient(
            gradient: Gradient(stops: [
                Gradient.Stop(color: .white.opacity(0), location: 0),
                Gradient.Stop(color: .white.opacity(0.5), location: height > 0 ? fade / height * 0.5 : 0),
                Gradient.Stop(color: .white, location: height > 0 ? fade / height : 0),
                Gradient.Stop(color: .white, location: 1)
            ]),
            startPoint: .top, endPoint: .bottom)
    }
}

/// The window on the body of a poem (a fixed viewport with the body moved
/// through it).
///
/// The body is drawn in a frame of the height of the window; the part that
/// does not fit stays outside. The line that is cut at the top of the window
/// fades out instead of ending in the middle of a letter.
///
/// The break window itself reads in a scrollable viewport
/// (`PoemReadingViewport`); this fixed one only renders — the poem probe
/// draws with it into an image, where a scroll view has no place.
struct PoemViewport<Content: View>: View {
    /// The width the body is laid out in.
    let width: CGFloat
    /// The height of the window on the body.
    let height: CGFloat
    /// The height of the whole body.
    let contentHeight: CGFloat
    /// How far the body has moved up.
    let offset: CGFloat
    /// True when the body is cut at the top of the window.
    let fadesTop: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: .top)
            .frame(height: contentHeight, alignment: .top)
            .offset(y: -offset)
            .frame(height: height, alignment: .top)
            .clipped()
            .mask(topFade)
    }

    /// The fade at the top of the window.
    @ViewBuilder
    private var topFade: some View {
        if fadesTop, height > 0 {
            PoemTopFade(height: height)
        } else {
            Color.white
        }
    }
}

/// The scroll view of the reading viewport.
///
/// A subclass, because the reading viewport has to know when the reader takes
/// over: every way of moving the viewport — the wheel, the trackpad, the
/// native slider, the track, the keyboard — lands in the bounds of the clip
/// view, so that is what is observed. Once the reader moved it, the automatic
/// travel of the poem keeps its hands off: the reader is never dragged back
/// to a position the clock has computed.
final class PoemScrollView: NSScrollView {
    /// Called when the cursor enters or leaves the poem area.
    var onHoverChanged: ((Bool) -> Void)?
    /// Called on the next pass of the main run loop after the reading
    /// position changed, with the reading position (0 at the top, 1 at the
    /// newest words). Never called for a move the follow caused itself.
    var onReaderScrolled: ((Double) -> Void)?
    /// The focus the bridge reports the reading anchor to.
    var focusController: PoemFocusController?
    /// True once the reader took over with a scroll gesture; the view sets it
    /// itself when it sees the position change by a hand other than the
    /// follow's. It can be set before the first event: a rebuilt window that
    /// already lost the travel to the reader seeds it here, so the travel
    /// stays off.
    var userScrolled = false
    /// The bounds origin the follow scrolled to last. A later bounds change
    /// that still equals it is a follow move, not a reader scroll — and when
    /// no bounds change happened at all, the value goes stale on its own and
    /// can never swallow the next real gesture.
    var programmaticOrigin: NSPoint?
    /// The focus of a growing poem while the follow has it: the anchor locks
    /// on the frontier line, so the scroll clamping at the end of the
    /// document can never make an older line the brightest.
    var lockedFollowAnchorY: CGFloat?
    /// The measured geometry of the shown poem: the bridge reads the focus at
    /// the reading position from it (the first and the last line with words
    /// of the whole revealed document).
    var focusGeometry: PoemFocusGeometry?
    /// The hover state this view reported last (nil before the first sync).
    private var reportedHover: Bool?
    /// True while a hover sync waits for the next pass of the main run loop.
    private var hoverSyncQueued = false
    /// True while a reading-position report waits for the next pass.
    private var readerSyncQueued = false
    /// The reading position the viewport was born with (and last reported):
    /// only a change from this origin by a hand other than the follow's is a
    /// reader scroll — a layout, a resize or a repeated sync never is.
    private var lastKnownOrigin: NSPoint?
    /// The anchor last published: the same anchor is never published twice.
    private var lastReportedAnchorY: CGFloat?
    /// Probe support: how often the bounds changed and the report ran.
    private(set) var boundsChangeCount = 0
    private(set) var reportCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        lastKnownOrigin = contentView.bounds.origin
        // The native scroll path: the clip view posts this notification for
        // every bounds change — the slider, the track, the keyboard, the
        // wheel and the follow all land in it (see `follow(to:)`).
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("PoemScrollView is created in code only")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        boundsChangeCount &+= 1
        scheduleReaderSync()
    }

    /// The reading position of the viewport: 0 at the top of the poem, 1 at
    /// its end.
    func readingFraction() -> Double {
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        guard maxY > 0 else { return 0 }
        return Double(min(max(contentView.bounds.origin.y / maxY, 0), 1))
    }

    /// The y of the reading anchor of the current position: the focus travels
    /// with the scroll, from the first line with words of the poem to its
    /// last one. The review of a reader and the travel of the complete poem
    /// read at the same place this way, so they never disagree about where
    /// the poem is read.
    private func readingAnchorY() -> CGFloat? {
        guard let geometry = focusGeometry else { return nil }
        guard let anchor = PoemFocus.scrollAnchorY(centers: geometry.centers.map(Double.init),
                                                   hasWords: geometry.hasWords,
                                                   fraction: readingFraction()) else { return nil }
        return CGFloat(anchor)
    }

    /// A follow move: the viewport is placed at the origin without ever
    /// looking like a reader scroll.
    func follow(to origin: NSPoint) {
        programmaticOrigin = origin
        if contentView.bounds.origin != origin {
            contentView.scroll(to: origin)
        }
    }

    /// The cursor is tracked while the app is not active: the break window
    /// never becomes key, and the poem still reacts to the reader.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        reportHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        reportHover(false)
    }

    /// A view that appears without the mouse moving never sees an enter
    /// event: after mounting and after the layout settles, the real position
    /// of the cursor is read once from the system and reported. Nothing is
    /// moved and nothing is activated.
    ///
    /// The sync is deferred to the next pass of the main run loop: mounting
    /// and layout run before the break state is started, so reporting now
    /// would be dropped — and a view must never publish state while the view
    /// tree is being updated.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleHoverSync()
        scheduleReaderSync()
    }

    override func layout() {
        super.layout()
        scheduleHoverSync()
        scheduleReaderSync()
    }

    /// Queues one hover sync for the next run loop pass; a view may call
    /// `layout` repeatedly, but the sync runs at most once per pass.
    private func scheduleHoverSync() {
        guard window != nil, !hoverSyncQueued else { return }
        hoverSyncQueued = true
        let window = self.window
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hoverSyncQueued = false
            // Only a view that still lives in the same window reads its
            // position; a discarded view of a rebuilt window reports nothing.
            guard self.window != nil, self.window === window else { return }
            self.syncHover()
        }
    }

    /// Queues one reading-position report for the next run loop pass. The
    /// clip view may report many bounds changes while the reader drags the
    /// slider; they merge into one report per pass, so the brightness follows
    /// the position continuously without stacking animations.
    private func scheduleReaderSync() {
        guard window != nil, !readerSyncQueued else { return }
        readerSyncQueued = true
        let window = self.window
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readerSyncQueued = false
            guard self.window != nil, self.window === window else { return }
            self.reportReadingPosition()
        }
    }

    /// Reports the reading anchor and, only when the reading position really
    /// changed by a hand other than the follow's, the reader scroll. A
    /// layout, a resize, a repeated sync or the mounting of the view move
    /// nothing and are no review; the same anchor is never published twice.
    private func reportReadingPosition() {
        reportCount &+= 1
        let bounds = contentView.bounds
        let programmatic = programmaticOrigin == bounds.origin
        programmaticOrigin = nil
        if !programmatic, bounds.origin != lastKnownOrigin {
            // A real reader gesture: the review starts here, and the anchor
            // of this very pass already reads at the review position.
            userScrolled = true
            onReaderScrolled?(readingFraction())
        }
        lastKnownOrigin = bounds.origin
        let anchorY: CGFloat?
        if !userScrolled, let locked = lockedFollowAnchorY {
            // The follow of a growing poem locks its focus on the frontier
            // line: the scroll clamps at the ends of the document, but the
            // brightest line stays the newest one.
            anchorY = locked
        } else {
            // Everything else reads at the reading position itself: a review
            // of the reader and the travel of the complete poem share the
            // same mapping, so the top of the poem reads at its first line
            // and its end at its last one.
            anchorY = readingAnchorY()
        }
        if let anchorY, anchorY != lastReportedAnchorY {
            lastReportedAnchorY = anchorY
            focusController?.anchorY = anchorY
        }
    }

    /// Reports the real inside state of the cursor once — only when it
    /// differs from what this view reported before.
    func syncHover() {
        guard window != nil, !bounds.isEmpty else { return }
        reportHover(isMouseInside())
    }

    private func isMouseInside() -> Bool {
        guard let window else { return false }
        let location = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return visibleRect.contains(location)
    }

    private func reportHover(_ inside: Bool) {
        guard reportedHover != inside else { return }
        reportedHover = inside
        onHoverChanged?(inside)
    }
}

/// The scroller of the reading viewport: a slim capsule over the poem.
///
/// The native `NSScroller` subclass keeps AppKit's knob geometry and every
/// interaction (the drag, the track click, the wheel, the keyboard, the
/// overlay timing) — only the drawing changes: the slot is never drawn, so
/// the poem shows through the whole track in the overlay and in the legacy
/// style, and the thumb is a quiet white capsule that belongs to the white
/// verses.
final class PoemScroller: NSScroller {
    /// Certified compatible with the overlay presentation, per the
    /// `NSScroller` subclass contract: the customization overrides only the
    /// parts-drawing methods (no `drawRect`, no event overrides) and copes
    /// with the overlay metrics. Without this, AppKit assumes the opposite
    /// and demotes the reader's overlay preference to legacy for this
    /// scroller.
    override class var isCompatibleWithOverlayScrollers: Bool {
        self === PoemScroller.self
    }

    /// The share of the scroller width the capsule keeps clear at each side.
    private var sideInset: CGFloat {
        bounds.width > 0 ? bounds.width * 0.2 : 0
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track: the poem shows through the whole slot.
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        let capsule = knobRect.insetBy(dx: sideInset, dy: knobRect.height * 0.02)
        guard capsule.width > 1, capsule.height > 1 else { return }
        // Increased Contrast reads a little stronger; the geometry stays.
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? 0.85 : 0.55
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: capsule,
                     xRadius: capsule.width / 2,
                     yRadius: capsule.width / 2).fill()
    }
}

/// The reading viewport of the break window: a scroll view with the poem as
/// its document.
///
/// SwiftUI has no scroll view that follows the rules of this window: the
/// travel of the complete poem has to be paced by the break, the newest words
/// of a growing poem have to sit at the follow anchor of the viewport, and a
/// reader who scrolls back must never be dragged back. A small AppKit bridge
/// keeps these decisions where the AppKit window is.
struct PoemScrollViewport<Content: View>: NSViewRepresentable {
    /// The width the body is laid out in.
    let width: CGFloat
    /// The height of the viewport.
    let height: CGFloat
    /// The height of the whole body (measured with the same face it draws with).
    let contentHeight: CGFloat
    /// The offset the follow wants: the place of the newest words of a growing
    /// poem, the end of the document of a complete one. The reader's own
    /// scroll takes over from there.
    let followOffset: CGFloat?
    /// The y of the frontier line in the coordinates of the document: while
    /// the follow has a growing poem, the focus locks on it — the scroll
    /// clamps at the ends, the brightest line does not move. `nil` for the
    /// complete poem (its focus follows the reading position).
    let followAnchorY: CGFloat?
    /// The measured geometry of the body: the bridge reads the focus at the
    /// reading position from it.
    let geometry: PoemFocusGeometry
    /// True when the reader already scrolled: the travel keeps its hands off.
    /// A rebuilt window seeds this, so it never drags the reader along.
    let userScrolled: Bool
    /// The reading position the viewport starts at (0 at the top, 1 at the
    /// newest words); `nil` follows the poem instead.
    let initialFraction: Double?
    /// The focus the bridge reports the reading anchor to.
    let focusController: PoemFocusController
    /// The identity of the content: when it changes, the hosted poem is
    /// rebuilt, so the focus style always reaches the hosted tree.
    let contentKey: AnyHashable
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onReaderScrolled: (Double) -> Void = { _ in }

    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> PoemScrollView {
        let scrollView = PoemScrollView()
        scrollView.verticalScroller = PoemScroller()
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.onHoverChanged = onHoverChanged
        scrollView.onReaderScrolled = onReaderScrolled
        scrollView.userScrolled = userScrolled
        scrollView.focusController = focusController
        scrollView.lockedFollowAnchorY = followAnchorY
        scrollView.focusGeometry = geometry
        let hosting = NSHostingView(rootView: content())
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        scrollView.documentView = hosting
        scrollView.setAccessibilityElement(true)
        scrollView.setAccessibilityRole(.scrollArea)
        return scrollView
    }

    func updateNSView(_ scrollView: PoemScrollView, context: Context) {
        guard let hosting = scrollView.documentView as? NSHostingView<Content> else { return }
        scrollView.onHoverChanged = onHoverChanged
        scrollView.onReaderScrolled = onReaderScrolled
        scrollView.focusController = focusController
        scrollView.lockedFollowAnchorY = followAnchorY
        scrollView.focusGeometry = geometry
        let frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        if hosting.frame != frame {
            hosting.frame = frame
        }
        // The content only changes with the session of the break. When it
        // does, the hosted poem is rebuilt (the focus style has to reach the
        // hosted tree) and the viewport starts reading at the top again.
        if context.coordinator.contentKey != contentKey {
            context.coordinator.contentKey = contentKey
            context.coordinator.didInitialScroll = false
            hosting.rootView = content()
        }
        let maxY = max(0, documentHeight - height)
        if !context.coordinator.didInitialScroll {
            // The first layout: the reading area stands where the poem wants
            // to be read — the newest words of a growing poem, the end of a
            // complete one — or where the reader scrolled to.
            context.coordinator.didInitialScroll = true
            let origin: NSPoint
            if let initialFraction {
                origin = NSPoint(x: 0, y: initialFraction * maxY)
            } else {
                origin = followOrigin(maxY: maxY)
            }
            scrollView.follow(to: origin)
        }
        guard !scrollView.userScrolled else { return }
        if let followOffset {
            // The follow holds the place the poem wants to be read at. The
            // position is only set when it actually moves: a standing poem is
            // not scrolled again and again.
            scrollView.follow(to: NSPoint(x: 0, y: min(max(followOffset, 0), maxY)))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var didInitialScroll = false
        var contentKey: AnyHashable?
    }

    /// The offset the follow wants right now: the place of the newest words,
    /// at the end of the document for a complete poem.
    private func followOrigin(maxY: CGFloat) -> NSPoint {
        let y = min(max(followOffset ?? 0, 0), maxY)
        return NSPoint(x: 0, y: y)
    }

    /// The height of the document: the body, or the whole viewport when the
    /// body is shorter (it is still scrollable then, but nothing moves).
    private var documentHeight: CGFloat {
        max(height, contentHeight)
    }
}

/// The reading viewport on the poem of a break: the scroll view with the
/// body, framed and faded at the top where the body has moved past it.
struct PoemReadingViewport<Content: View>: View {
    /// The width the body is laid out in.
    let width: CGFloat
    /// The height of the viewport.
    let height: CGFloat
    /// The height of the whole body.
    let contentHeight: CGFloat
    /// True when the body is cut at the top of the viewport.
    let fadesTop: Bool
    /// The offset the follow wants: the place of the newest words of a growing
    /// poem, the end of the document of a complete one.
    let followOffset: CGFloat?
    /// The y of the frontier line in the coordinates of the document: while
    /// the follow has a growing poem, the focus locks on it — the scroll
    /// clamps at the ends, the brightest line does not move. `nil` for the
    /// complete poem (its focus follows the reading position).
    let followAnchorY: CGFloat?
    /// The measured geometry of the body: the bridge reads the focus at the
    /// reading position from it.
    let geometry: PoemFocusGeometry
    /// True when the reader already scrolled: the poem stays where they put
    /// it — the follow keeps its hands off.
    let userScrolled: Bool
    /// The reading position the viewport starts at; `nil` follows the poem.
    let initialFraction: Double?
    /// The focus the bridge reports the reading anchor to.
    let focusController: PoemFocusController
    /// The identity of the content (rebuilds the hosted poem when it changes).
    let contentKey: AnyHashable
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onReaderScrolled: (Double) -> Void = { _ in }

    @ViewBuilder var content: () -> Content

    var body: some View {
        PoemScrollViewport(width: width, height: height, contentHeight: contentHeight,
                           followOffset: followOffset,
                           followAnchorY: followAnchorY,
                           geometry: geometry,
                           userScrolled: userScrolled,
                           initialFraction: initialFraction,
                           focusController: focusController,
                           contentKey: contentKey,
                           onHoverChanged: onHoverChanged,
                           onReaderScrolled: onReaderScrolled,
                           content: content)
            .frame(width: width, height: height)
            .mask(topFade)
    }

    /// The fade at the top of the viewport.
    @ViewBuilder
    private var topFade: some View {
        if fadesTop, height > 0 {
            PoemTopFade(height: height)
        } else {
            Color.white
        }
    }
}

/// A quiet view that reports the cursor on the area it is placed in.
///
/// The credit line of the poem (the author and the name of the poem) is a
/// SwiftUI text in a window that never becomes key: `onHover` cannot be
/// relied on there. A tracking area with `activeAlways` reports the cursor
/// while the app is not active — without activating anything, without global
/// event monitors.
struct PoemHoverArea: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onChange: onChange)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        /// The hover state this view reported last (nil before the first sync).
        private var reportedHover: Bool?
        /// True while a hover sync waits for the next pass of the main run loop.
        private var syncQueued = false

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("PoemHoverArea.TrackingView is created in code only")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if !trackingAreas.contains(where: { $0.owner === self }) {
                addTrackingArea(NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self, userInfo: nil))
            }
        }

        override func mouseEntered(with event: NSEvent) {
            reportHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            reportHover(false)
        }

        /// A view that appears without the mouse moving never sees an enter
        /// event: after mounting and after the layout settles, the real
        /// position of the cursor is read once from the system and reported.
        /// Nothing is moved and nothing is activated.
        ///
        /// The sync is deferred to the next pass of the main run loop:
        /// mounting and layout run before the break state is started, so
        /// reporting now would be dropped — and a view must never publish
        /// state while the view tree is being updated.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleHoverSync()
        }

        override func layout() {
            super.layout()
            scheduleHoverSync()
        }

        /// Queues one hover sync for the next run loop pass.
        private func scheduleHoverSync() {
            guard window != nil, !syncQueued else { return }
            syncQueued = true
            let window = self.window
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncQueued = false
                guard self.window != nil, self.window === window else { return }
                self.syncHover()
            }
        }

        private func syncHover() {
            guard window != nil, !bounds.isEmpty else { return }
            reportHover(isMouseInside())
        }

        private func isMouseInside() -> Bool {
            guard let window else { return false }
            let location = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            return visibleRect.contains(location)
        }

        private func reportHover(_ inside: Bool) {
            guard reportedHover != inside else { return }
            reportedHover = inside
            onChange(inside)
        }
    }
}
