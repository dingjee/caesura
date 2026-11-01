import AppKit
import SwiftUI
import CaesuraCore

/// One break window's content — native port of microbreak/break.html + renderers:
/// idea text, shrinking progress bar, remaining countdown (or elapsed in manual-await),
/// postpone/skip buttons gated by the captured policy, optional clock, and the
/// break-health glow. Counting uses the captured `started` instant (elapsed time),
/// exactly like the legacy renderer's 100 ms tick.
struct BreakContentView: View {
    struct Model {
        var mini: Bool
        var ideaMini: String
        var ideaLongTitle: String
        var ideaLongText: String
        var started: Int64
        var duration: Int64
        /// The duration of the short (Mini) break: the action button has the
        /// size of the short break in every break.
        var miniDuration: Int64
        var strictMode: Bool
        var postponable: Bool
        var postponableDurationPercent: Double
        var backgroundColor: Color
        var foregroundColor: Color
        var danger: Int
        var breakHealthMode: Bool
        var themeColor: String
        var blank: Bool
        var showClock: Bool
        var clockFontSize: Double
        var clockFormat: String
        var shortcutHint: String
        var localization: Localization
        var imagesDirectory: URL
        /// The poem of this break (nil when the break shows other content:
        /// custom ideas, a CLI text or no ideas at all).
        var poem: PoemBreakSession?
    }

    @ObservedObject var state: BreakWindowState
    let model: Model
    var onPostpone: () -> Void
    var onFinish: () -> Void
    /// The appearance of the window: the material of the glass pill follows it,
    /// and so does the ink of the label.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(model.backgroundColor)
                if !model.blank, let effect = Utils.breakHealthEffect(danger: model.danger,
                                                                     breakHealthMode: model.breakHealthMode,
                                                                     themeColor: model.themeColor) {
                    HealthGlow(effect: effect).ignoresSafeArea()
                }
                if model.blank {
                    EmptyView()
                } else {
                    // The poem is centred in the upper part of the window; the
                    // progress ring and the actions are anchored to the bottom,
                    // with a margin that is a share of the screen height.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if model.poem != nil {
                            poemBreakView(proxy: proxy)
                        } else if model.mini {
                            ideaView(proxy: proxy)
                        } else {
                            longIdeaView(proxy: proxy)
                        }
                        Spacer(minLength: proxy.size.height * 0.07)
                        controlsView(proxy: proxy)
                    }
                    .padding(.bottom, proxy.size.height * 0.06)
                    .padding(proxy.size.width * 0.05)
                }
            }
        }
    }

    /// The poem of a break: the body (in paragraphs), the name of the poem and,
    /// if it is on, the clock.
    ///
    /// The order is the reading order of a poem: the verses, then who wrote
    /// them, then the name of the poem, and last the time — the time is a
    /// separate paragraph with a little more room before it.
    private func poemView(body: String, title: String,
                          proxy: GeometryProxy) -> some View {
        let bodyNodes = IdeaSanitizer.sanitize(body)
        let paragraphs = IdeaParagraphs.paragraphs(from: bodyNodes)
        let renderedBody = IdeaTextBuilder.render(nodes: bodyNodes, imagesDirectory: model.imagesDirectory)
        let renderedTitle = IdeaTextBuilder.render(nodes: IdeaSanitizer.sanitize(title),
                                                   imagesDirectory: model.imagesDirectory)
        return VStack(spacing: proxy.size.height * 0.014) {
            if !renderedBody.images.isEmpty {
                ForEach(renderedBody.images) { image in
                    image_view(image)
                }
            }
            // The verses: one text per paragraph, so that a sentence end gets
            // the little more room that closes it.
            VStack(spacing: proxy.size.height * 0.012) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    let rendered = IdeaTextBuilder.render(nodes: paragraph, imagesDirectory: model.imagesDirectory)
                    if !rendered.attributed.runs.isEmpty {
                        Text(rendered.attributed)
                            .font(BreakTypography.serif(.body, height: proxy.size.height,
                                                        weight: .medium, italic: true))
                            .minimumScaleFactor(0.4)
                            .multilineTextAlignment(.center)
                            .foregroundColor(model.foregroundColor)
                            .environment(\.openURL, OpenURLAction { url in
                                NSWorkspace.shared.open(url)
                                return .handled
                            })
                    }
                }
            }
            // The author and the name of the poem on one line: the author
            // upright, the name of the poem after it.
            PoemCreditView(author: AttributedString(),
                           title: renderedTitle.attributed,
                           color: model.foregroundColor,
                           height: proxy.size.height)
            // The time, in a paragraph of its own with more room before it.
            if model.showClock {
                ClockView(font: BreakTypography.georgia(size: model.clockFontSize),
                          format: model.clockFormat)
                    .foregroundColor(model.foregroundColor.opacity(0.75))
                    .padding(.top, proxy.size.height * 0.02)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func ideaView(proxy: GeometryProxy) -> some View {
        poemView(body: model.ideaMini, title: "",
                 proxy: proxy)
    }

    private func longIdeaView(proxy: GeometryProxy) -> some View {
        // A long poem must not overflow the window: the capped frame makes
        // SwiftUI scale the texts down (never below the scale factor) instead
        // of spilling the trailing lines behind the controls.
        poemView(body: model.ideaLongText, title: model.ideaLongTitle, proxy: proxy)
            .frame(maxWidth: .infinity, maxHeight: proxy.size.height * 0.62)
    }

    /// The poem of a break: the lines around the frontier while the poem grows,
    /// the whole poem once it is complete, with the credit (the author and the
    /// name of the poem) below it and, if it is on, the clock.
    ///
    /// The verses, the name of the poem and the author fade in and out as one
    /// group. Their space stays reserved while they are hidden, so the layout
    /// of the window does not jump. The clock is not part of the poem: it stays
    /// visible.
    @ViewBuilder
    private func poemBreakView(proxy: GeometryProxy) -> some View {
        if let session = model.poem {
            VStack(spacing: proxy.size.height * 0.014) {
                poemText(session: session, proxy: proxy)
                    .opacity(state.poemOpacity)
                // The credit is not one of the verses: it stays outside the
                // window on the body, so that it is never cut. It fades with
                // the verses as one group: once the poem is gone, no residual
                // line is left behind until the break ends.
                PoemCreditView(author: AttributedString(session.author.isEmpty ? "" : "— \(session.author)"),
                               title: AttributedString(session.title),
                               color: model.foregroundColor,
                               height: proxy.size.height)
                    .opacity(state.poemOpacity)
                // The time, in a paragraph of its own with more room before it.
                if model.showClock {
                    ClockView(font: BreakTypography.georgia(size: model.clockFontSize),
                              format: model.clockFormat)
                        .foregroundColor(model.foregroundColor.opacity(0.75))
                        .padding(.top, proxy.size.height * 0.02)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: proxy.size.height * 0.62)
        }
    }

    /// The poem of the break itself: the frontier window with the soft edge
    /// while the poem grows, the whole poem once it is complete.
    ///
    /// The body is measured before it is drawn: it is drawn with the size of
    /// the type scale, as long as it fits into the window on the body. A
    /// longer body is drawn with a smaller type (never below 18 pt) and, if
    /// it does not fit even then, it moves through the window.
    @ViewBuilder
    private func poemText(session: PoemBreakSession, proxy: GeometryProxy) -> some View {
        let width = proxy.size.width * 0.9
        let spacing = proxy.size.height * 0.012
        // The room the verses have: the credit and the clock are drawn below
        // them.
        let budget = proxy.size.height * 0.38
        let preview = session.preview
        let lines = session.mode == .full ? session.lines : preview.lines
        let layout = PoemBodyLayoutResolver.resolve(
            lines: lines,
            natural: BreakTypography.size(.body, forHeight: proxy.size.height),
            width: width,
            height: budget,
            spacing: spacing,
            font: { size in
                BreakTypography.serifFont(size: size, weight: .medium, italic: true)
            })
        let viewport = min(layout.contentHeight, budget)
        if session.mode == .full {
            // The poem is complete: every line is shown, without a soft edge,
            // and the poem travels from its beginning to its end while it is
            // shown.
            if state.poemOpacity > 0 {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    fullPoem(session: session, layout: layout, viewport: viewport,
                             width: width, spacing: spacing,
                             offset: poemOffset(session: session, layout: layout,
                                                viewport: viewport, now: context.date))
                }
            } else {
                fullPoem(session: session, layout: layout, viewport: viewport,
                         width: width, spacing: spacing, offset: 0)
            }
        } else {
            // The frontier with the line before it: it stays at the bottom of
            // the window, so that the newest words are never cut.
            PoemRevealView(preview: preview,
                           font: BreakTypography.serif(size: layout.fontSize,
                                                      weight: .medium, italic: true),
                           nsFont: BreakTypography.serifFont(size: layout.fontSize,
                                                             weight: .medium, italic: true),
                           color: model.foregroundColor,
                           width: width,
                           spacing: spacing,
                           viewportHeight: viewport,
                           contentHeight: layout.contentHeight,
                           offset: max(0, layout.contentHeight - viewport),
                           fadesTop: layout.overflows)
        }
    }

    /// The whole poem of the break, at the given moment of it.
    private func fullPoem(session: PoemBreakSession, layout: PoemBodyLayout,
                          viewport: CGFloat, width: CGFloat, spacing: CGFloat,
                          offset: CGFloat) -> some View {
        PoemBreakView(session: session,
                      font: BreakTypography.serif(size: layout.fontSize,
                                                 weight: .medium, italic: true),
                      color: model.foregroundColor,
                      width: width,
                      spacing: spacing,
                      viewportHeight: viewport,
                      contentHeight: layout.contentHeight,
                      offset: offset,
                      // The top only fades where the poem has actually moved:
                      // a poem that fits stands still and is not masked.
                      fadesTop: layout.overflows && offset > 0)
    }

    /// How far the poem has moved at that moment: it travels from its
    /// beginning to its end while it is shown.
    ///
    /// The system asks for less movement: the poem then stands still, like it
    /// appears and disappears at once.
    private func poemOffset(session: PoemBreakSession, layout: PoemBodyLayout,
                            viewport: CGFloat, now: Date) -> CGFloat {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        let timeline = PoemTimeline.scaled(mini: session.mini, toDuration: session.durationMillis)
        guard timeline.totalMillis > 0 else { return 0 }
        let elapsed = Int64(now.timeIntervalSince1970 * 1000) - session.startedAt
        // The poem arrives at its end before the hold is over and stays there:
        // the last lines have to stay readable at the bottom while the poem is
        // still visible, not vanish with the fade-out.
        let travelWindow = Double(timeline.fadeInMillis + timeline.holdMillis) * 0.85
        guard travelWindow > 0 else { return 0 }
        let progress = min(max(Double(elapsed) / travelWindow, 0), 1)
        return progress * max(0, layout.contentHeight - viewport)
    }

    @ViewBuilder
    private func image_view(_ ref: IdeaTextBuilder.ImageRef) -> some View {
        if let url = ref.url, let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 160)
                .accessibilityLabel(Text(ref.alt ?? ref.filename))
        }
    }

    /// The diameter of the progress ring (the time circle bar).
    ///
    /// The ring is scaled with the duration of the break: the area it encloses
    /// is proportional to the duration (20 s : 300 s), which is the same as a
    /// radius that scales with the square root of the duration. The area of the
    /// filled sector then grows at the same rate in every break, so the ring
    /// reads with the same pace in a short and in a long break.
    ///
    /// The reference is the diameter a 300-second break gets (a share of the
    /// window height); the clamps keep a very short break legible and a very
    /// long one from squeezing the poem out of its capped frame.
    private func ringSize(_ proxy: GeometryProxy) -> CGFloat {
        ringSize(duration: model.duration, proxy: proxy)
    }

    /// The diameter of the progress ring of a break of the given duration.
    private func ringSize(duration: Int64, proxy: GeometryProxy) -> CGFloat {
        let referenceSeconds: Double = 300
        let seconds = max(1, Double(duration) / 1000)
        // The diameter a 300-second break gets: a share of the window height.
        let referenceDiameter = min(max(proxy.size.height * 0.15, 64), 140)
        // Three times the area of the first circle: the radius grows by √3.
        let areaFactor = CGFloat(3.0.squareRoot())
        let diameter = referenceDiameter * areaFactor
            * CGFloat((seconds / referenceSeconds).squareRoot())
        return min(max(diameter, 22), referenceDiameter * areaFactor)
    }

    /// The diameter of the action button.
    ///
    /// The button is decoupled from the progress ring: the ring keeps the size
    /// of the break, the button has the size of the short break in every break.
    /// So the button and its glyph look the same in a Mini and in a Long break.
    private func buttonSize(_ proxy: GeometryProxy) -> CGFloat {
        ringSize(duration: model.miniDuration, proxy: proxy)
    }

    private func ringLineWidth(_ proxy: GeometryProxy) -> CGFloat {
        max(3, ringSize(proxy) * 0.08)
    }

    /// The action of the break: a round glass control whose glyph in the middle
    /// is the action itself. The name of the action is the tooltip of the
    /// control, not a label under it.
    ///
    /// The control and the progress ring are two separate things: the ring (the
    /// time circle bar) keeps the size of the break and surrounds the button,
    /// the button itself has the size of the short break and sits in its
    /// centre.
    private func actionButton(proxy: GeometryProxy) -> some View {
        let ring = ringSize(proxy)
        let button = buttonSize(proxy)
        let action = currentAction
        let ink = colorScheme == .dark ? Color(white: 0.95) : Color(white: 0.12)
        let theme = Color(hex: Utils.opaqueColor(model.themeColor)) ?? model.foregroundColor
        return ZStack {
            Button {
                action.perform?()
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(theme.opacity(0.3)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.2), radius: 10, y: 3)
                    Image(systemName: action.symbol)
                        .font(.system(size: max(10, button * 0.3), weight: .medium))
                        .foregroundStyle(ink)
                }
                .frame(width: button, height: button)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // The ring is drawn over the button: in the short break it is the
            // rim of the button, in the long break it surrounds it.
            ProgressRing(fraction: state.progressFraction,
                         foreground: ink,
                         lineWidth: ringLineWidth(proxy))
                .frame(width: ring, height: ring)
                .allowsHitTesting(false)
        }
        // In strict mode there is no action: the circle stays the progress.
        .allowsHitTesting(action.perform != nil)
        .help(action.help)
        .accessibilityLabel(Text(action.title))
    }

    /// The action the break offers right now: the postpone in the first part
    /// of the break, the skip after it, the finish while the break waits for it.
    private var currentAction: (symbol: String, title: String, help: String, perform: (() -> Void)?) {
        if state.manualAwait {
            return ("checkmark.circle.fill", model.localization.t("break.finishShort"),
                    model.localization.t("break.finish"), onFinish)
        }
        if state.canPostpone {
            return ("clock.arrow.circlepath", model.localization.t("break.postponeShort"),
                    model.localization.t("break.postpone"), onPostpone)
        }
        if state.canSkip {
            return ("forward.fill", model.localization.t("break.skipShort"),
                    model.localization.t("break.skip"), onFinish)
        }
        return ("", "", "", nil)
    }

    /// The centered column below the poem: the progress button.
    /// There is no countdown label — the rim of the button carries the progress
    /// of the break.
    private func controlsView(proxy: GeometryProxy) -> some View {
        actionButton(proxy: proxy)
            .frame(maxWidth: .infinity)
    }

}

/// The poem of a break: the whole poem, line by line, in the window on the
/// body.
struct PoemBreakView: View {
    let session: PoemBreakSession
    let font: Font
    let color: Color
    /// The width the poem is laid out in.
    let width: CGFloat
    /// The spacing between the lines of the poem.
    let spacing: CGFloat
    /// The height of the window on the poem.
    let viewportHeight: CGFloat
    /// The height of the whole poem.
    let contentHeight: CGFloat
    /// How far the poem has moved up.
    let offset: CGFloat
    /// True when the poem is cut at the top of the window.
    let fadesTop: Bool

    var body: some View {
        PoemViewport(width: width,
                     height: viewportHeight,
                     contentHeight: contentHeight,
                     offset: offset,
                     fadesTop: fadesTop) {
            VStack(spacing: spacing) {
                ForEach(Array(session.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(font)
                        .multilineTextAlignment(.center)
                        .foregroundColor(color)
                }
            }
        }
    }
}

/// The poem of a break while it grows: the lines around the frontier, with
/// the shared soft edge at the end of the frontier line.
///
/// Only the lines around the frontier are shown: the poem of the break grows
/// from its beginning over the breaks.
struct PoemRevealView: View {
    let preview: PoemRevealPreview
    let font: Font
    /// The same face as `font`, measured with CoreText.
    let nsFont: NSFont
    let color: Color
    /// The width the poem is laid out in.
    let width: CGFloat
    /// The spacing between the lines of the poem.
    let spacing: CGFloat
    /// The height of the window on the poem.
    let viewportHeight: CGFloat
    /// The height of the whole poem.
    let contentHeight: CGFloat
    /// How far the poem has moved up.
    let offset: CGFloat
    /// True when the poem is cut at the top of the window.
    let fadesTop: Bool

    var body: some View {
        PoemViewport(width: width,
                     height: viewportHeight,
                     contentHeight: contentHeight,
                     offset: offset,
                     fadesTop: fadesTop) {
            VStack(spacing: spacing) {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                    if index == preview.softEdgeLineIndex {
                        SoftEdgePoemLine(text: line,
                                         edgeOffset: preview.softEdgeOffset,
                                         font: font,
                                         nsFont: nsFont,
                                         color: color,
                                         availableWidth: width)
                    } else {
                        // The lines before the frontier are fully revealed: they
                        // stay clear, without a soft edge.
                        Text(line)
                            .font(font)
                            .multilineTextAlignment(.center)
                            .foregroundColor(color)
                    }
                }
            }
        }
    }
}

/// The width of a text, measured with CoreText.
///
/// The soft edge has to sit at a real place of the line, so the width of the
/// text (and of the part before the edge) is measured with the same face the
/// window draws with.
enum PoemTextMetrics {
    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}

/// The place of the soft edge inside a rendered line.
///
/// The edge starts at the end of the clear part of the centred line and ends
/// with the text. A line that does not fit on one row has no edge: its text
/// stays clear instead of guessing where the edge would be.
enum PoemSoftEdgeGeometry {
    static func edge(text: String, edgeOffset: Int, nsFont: NSFont,
                     availableWidth: CGFloat) -> PoemRevealSoftEdge? {
        let lineWidth = PoemTextMetrics.width(of: text, font: nsFont)
        let offset = min(max(edgeOffset, 0), text.count)
        let index = text.index(text.startIndex, offsetBy: offset)
        let clearWidth = PoemTextMetrics.width(of: String(text[..<index]), font: nsFont)
        guard lineWidth > 0, clearWidth < lineWidth, availableWidth > lineWidth else { return nil }
        // The text is centred in the line, so the edge starts at the end of the
        // clear part of the centred text.
        let startX = (availableWidth - lineWidth) / 2 + clearWidth
        return PoemRevealSoftEdge(startX: startX, width: lineWidth - clearWidth, tilt: 0.35)
    }
}

/// One line of the revealed poem with the shared diagonal soft edge at its end.
///
/// The edge is ONE continuous, slanted fade over the words at the end of the
/// revealed text — not a gradient per word, and not a fade over the whole
/// width of the window. Its position comes from the real geometry of the line:
/// the width the text needs and the width of the part before the edge.
struct SoftEdgePoemLine: View {
    let text: String
    /// The character offset where the soft edge starts (the first character of
    /// the first word that belongs to the edge).
    let edgeOffset: Int
    let font: Font
    /// The same face as `font`, measured with CoreText.
    let nsFont: NSFont
    let color: Color
    /// The width the line is laid out in.
    let availableWidth: CGFloat

    var body: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .mask(edgeMask)
    }

    /// The mask of the line: clear until the soft edge, then one slanted fade
    /// to the end of the text.
    @ViewBuilder
    private var edgeMask: some View {
        if let edge = PoemSoftEdgeGeometry.edge(text: text, edgeOffset: edgeOffset,
                                                nsFont: nsFont, availableWidth: availableWidth) {
            let axis = edge.axis()
            let lineHeight = max(1, nsFont.ascender - nsFont.descender + nsFont.leading)
            LinearGradient(
                gradient: Gradient(stops: PoemRevealSoftEdge.alphaProfile().map {
                    Gradient.Stop(color: .white.opacity($0.alpha), location: $0.position)
                }),
                startPoint: UnitPoint(x: axis.startX / availableWidth, y: axis.startY / lineHeight),
                endPoint: UnitPoint(x: axis.endX / availableWidth, y: axis.endY / lineHeight)
            )
        } else {
            // The line does not fit on one row (or nothing is measured yet):
            // the text stays clear instead of guessing where the edge is.
            Color.white
        }
    }
}

/// The credit under the poem: the author upright (not italic), the name of the
/// poem in italics after it as a second span.
struct PoemCreditView: View {
    let author: AttributedString
    let title: AttributedString
    let color: Color
    let height: CGFloat

    var body: some View {
        let authorSpan = Text(author)
            .font(BreakTypography.serif(.attribution, height: height))
            .foregroundColor(color.opacity(0.85))
        let titleSpan = Text(title)
            .font(BreakTypography.serif(.title, height: height, weight: .regular, italic: true))
            .foregroundColor(color.opacity(0.8))
        // The span between the author and the name of the poem: wide enough to
        // keep the two apart.
        let separator = Text("      ")
            .font(BreakTypography.serif(.attribution, height: height))
            .foregroundColor(color.opacity(0.45))
        let line: Text
        if author.runs.isEmpty {
            line = titleSpan
        } else if title.runs.isEmpty {
            line = authorSpan
        } else {
            line = authorSpan + separator + titleSpan
        }
        return line
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.4)
    }
}

/// 100 ms tick, mirroring the legacy renderer interval.
final class BreakWindowState: ObservableObject {
    @Published var progressFraction: Double = 1
    /// The opacity of the poem of the break: it fades in, waits and fades
    /// out again, and stays hidden until the break ends.
    @Published var poemOpacity: Double = 0
    @Published var manualAwait = false
    @Published var canPostpone = false
    @Published var canSkip = false
    private var timer: Timer?
    private var modelRef: BreakContentView.Model?
    /// The countdown end is reported once, not on every tick.
    private var didFireCountdownEnd = false
    var onCountdownEnd: (() -> Void)?
    /// The time envelope of the poem of this break.
    private var poemTimeline: PoemTimeline?
    /// The refresh of the poem of this break. It stops when the poem is gone.
    private var poemTimer: Timer?
    /// True when the poem of this break has faded out for good.
    private var poemFinished = false

    func start(model: BreakContentView.Model) {
        modelRef = model
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        startPoem(model: model)
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        poemTimer?.invalidate()
        poemTimer = nil
    }

    /// Starts the poem of the break.
    ///
    /// The timeline is measured from the captured start of the break, so a
    /// window that is rebuilt (a display change) continues the same animation
    /// instead of playing it again, and a poem that has already faded out stays
    /// hidden.
    private func startPoem(model: BreakContentView.Model) {
        poemTimer?.invalidate()
        poemTimer = nil
        poemTimeline = nil
        poemFinished = false
        poemOpacity = 0
        guard let session = model.poem else { return }
        let timeline = PoemTimeline.scaled(mini: session.mini, toDuration: model.duration)
        poemTimeline = timeline
        guard timeline.totalMillis > 0 else { return }
        updatePoemOpacity()
        guard !poemFinished else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.updatePoemOpacity()
        }
        RunLoop.main.add(timer, forMode: .common)
        poemTimer = timer
    }

    private func updatePoemOpacity() {
        guard let timeline = poemTimeline, let model = modelRef, !poemFinished else { return }
        let elapsed = SystemClock().nowMillis - model.started
        poemOpacity = timeline.opacity(at: elapsed, reduceMotion: reduceMotion)
        if elapsed >= timeline.totalMillis {
            // The poem is gone: no refresh for a hidden poem.
            poemFinished = true
            poemTimer?.invalidate()
            poemTimer = nil
        }
    }

    /// The system asks for less movement: the poem then appears and disappears
    /// at once, but it stays visible for the same time.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func enterManualAwait() {
        guard !manualAwait else { return }
        manualAwait = true
        progressFraction = 0
        canPostpone = false
        canSkip = false
        tick() // refresh elapsed label immediately
    }

    private func tick() {
        guard let model = modelRef else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let passed = now - model.started
        if !manualAwait {
            let passedPercent = Double(passed) / Double(model.duration) * 100
            progressFraction = max(0, min(1, 1 - passedPercent / 100))
            canPostpone = Utils.canPostpone(postpone: model.postponable,
                                            passedPercent: passedPercent,
                                            postponePercent: model.postponableDurationPercent)
            canSkip = Utils.canSkip(strictMode: model.strictMode,
                                    postpone: model.postponable,
                                    passedPercent: passedPercent,
                                    postponePercent: model.postponableDurationPercent)
        } else {
            progressFraction = 0
        }
        // The countdown end is reported once — also in the manual await phase,
        // which starts at the very moment the countdown is over. The break
        // really lasted its duration, whatever the phase is.
        if passed >= model.duration, !didFireCountdownEnd {
            didFireCountdownEnd = true
            onCountdownEnd?()
        }
    }
}

/// The break progress ring. `fraction` is the remaining amount (1 → 0, like the
/// legacy <progress> element); the visual arc is the elapsed share (1 - fraction),
/// starting at 12 o'clock and running clockwise. The accessibility value keeps
/// the same elapsed semantics.
struct ProgressRing: View {
    var fraction: Double
    var foreground: Color = .white
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(foreground.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, 1 - fraction))))
                .stroke(foreground,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityElement()
        .accessibilityLabel("Break progress")
        .accessibilityValue("\(Int((1 - fraction) * 100))% elapsed")
    }
}

struct ClockView: View {
    var font: Font
    var format: String
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .font(font)
            .monospacedDigit()
            .onReceive(timer) { date in
                now = date
            }
    }

    /// Legacy used luxon `toFormat`; the tokens are translated into an ICU pattern
    /// (see ClockFormat) instead of being passed through untranslated.
    private var formatted: String {
        let formatter = ClockFormat.formatter(fromLuxon: format)
        return formatter.string(from: now)
    }
}

struct HealthGlow: View {
    var effect: (red: Int, green: Int, blue: Int, opacity: Double, blur: Int, spread: Int)

    var body: some View {
        RoundedRectangle(cornerRadius: 0)
            .stroke(Color(red: Double(effect.red) / 255,
                          green: Double(effect.green) / 255,
                          blue: Double(effect.blue) / 255,
                          opacity: min(1, effect.opacity)),
                    lineWidth: CGFloat(effect.spread))
            .shadow(color: Color(red: Double(effect.red) / 255,
                                 green: Double(effect.green) / 255,
                                 blue: Double(effect.blue) / 255,
                                 opacity: min(1, effect.opacity)),
                    radius: CGFloat(effect.blur) / 3)
            .allowsHitTesting(false)
    }
}
