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
        /// The multiplier of the spacing of the poem's lines, captured with the
        /// settings at the moment the break was prepared (the next break reads
        /// the changed preference).
        var poemLineSpacing: Double = PoemSpacing.defaultFactor
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
    /// of the window does not jump — and the cursor can call the poem back
    /// from the hidden area. The clock is not part of the poem: it stays
    /// visible, and it does not hold the poem: only the cursor on the body or
    /// on the credit does.
    @ViewBuilder
    private func poemBreakView(proxy: GeometryProxy) -> some View {
        if let session = model.poem {
            VStack(spacing: proxy.size.height * 0.014) {
                poemText(session: session, proxy: proxy)
                    .opacity(state.poemOpacity)
                // The credit is not one of the verses: it stays outside the
                // window on the body, so that it is never cut. It fades with
                // the verses as one group, and the cursor on it keeps the poem
                // visible just like the cursor on the body does.
                PoemCreditView(author: AttributedString(session.author.isEmpty ? "" : "— \(session.author)"),
                               title: AttributedString(session.title),
                               color: model.foregroundColor,
                               height: proxy.size.height)
                    .opacity(state.poemOpacity)
                    .background(PoemHoverArea(onChange: { state.setPoemHover($0, region: .credit) }))
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

    /// The poem of the break itself: the revealed text from its beginning
    /// through the frontier, with the shared soft edge at its end while the
    /// poem grows, the whole poem once it is complete.
    ///
    /// The body is drawn at the size of the type scale — the comfortable size
    /// the display gives it. A longer body is never drawn with a smaller type:
    /// it becomes a longer scroll in the reading viewport. The reading area
    /// starts at its end, so the newest words of the poem are the ones that
    /// are read and the slider of the viewport stands at the bottom: a
    /// growing poem keeps its newest words at the follow anchor of the
    /// viewport (the revealed context above them), the complete poem shows
    /// its last lines. Nothing travels on its own any more — only the reader
    /// moves the poem, and the line they read is the brightest.
    @ViewBuilder
    private func poemText(session: PoemBreakSession, proxy: GeometryProxy) -> some View {
        let width = proxy.size.width * 0.9
        // The base spacing of the window times the reader's multiplier: the
        // measure, the line centres and the drawn stack all share one value.
        let spacing = CGFloat(PoemSpacing.spacing(base: Double(proxy.size.height * 0.012),
                                                  multiplier: model.poemLineSpacing))
        // The room the verses have: the credit and the clock are drawn below
        // them.
        let budget = proxy.size.height * 0.38
        let preview = session.preview
        let lines = session.mode == .full ? session.lines : preview.lines
        // The type keeps its size: the length of the poem is a length of the
        // scroll, not a smaller type.
        let layout = PoemBodyLayoutResolver.natural(
            lines: lines,
            natural: BreakTypography.size(.body, forHeight: proxy.size.height),
            width: width,
            height: budget,
            spacing: spacing,
            font: { size in
                BreakTypography.serifFont(size: size, weight: .medium, italic: true)
            })
        let viewportHeight = min(layout.contentHeight, budget)
        let mark = session.focusMark
        let centers = layout.lineCenters(spacing: spacing)
        let hasWords = lines.map { PoemWords.hasWords(in: $0) }
        let font = BreakTypography.serif(size: layout.fontSize, weight: .medium, italic: true)
        let nsFont = BreakTypography.serifFont(size: layout.fontSize, weight: .medium, italic: true)
        // The geometry only changes with the identity of the content; the
        // emphasis rules live in the focus controller and reach the hosted
        // tree live — a review or an accessibility change never rebuilds the
        // poem and never moves its scroll position.
        let geometry = PoemFocusGeometry(
            centers: centers,
            hasWords: hasWords,
            rowUnit: PoemFocus.rowUnit(heights: layout.lineHeights.map(Double.init)),
            // The complete poem that fits the viewport reads as one.
            uniform: session.mode == .full && !layout.overflows)
        let contentKey = Self.poemContentKey(lines: lines, width: width,
                                             height: proxy.size.height,
                                             fontSize: layout.fontSize,
                                             spacing: spacing,
                                             full: session.mode == .full)
        let frontierCenter = mark.frontierLine >= 0 && mark.frontierLine < centers.count
            ? centers[mark.frontierLine] : nil
        let maxOffset = max(0, layout.contentHeight - viewportHeight)
        // Where the reading area stands: at the end of the document, so that
        // the slider of the viewport is at the bottom and the newest words
        // are the ones that are read — in both modes. A growing poem keeps
        // its frontier as the brightest line (the anchor of the focus), the
        // complete poem reads at the position of the reader.
        let followOffset = maxOffset
        let followAnchorY: CGFloat? = session.mode == .full ? nil : frontierCenter
        PoemReadingViewport(width: width,
                            height: viewportHeight,
                            contentHeight: layout.contentHeight,
                            // The top only fades where the poem has actually
                            // moved past it: the reading area starts at its
                            // end, so the cut is the rule until the reader
                            // scrolls back to the first line.
                            fadesTop: layout.overflows && state.poemIsReadBelowItsFirstLine,
                            followOffset: followOffset,
                            // While the follow has a growing poem, the focus
                            // locks on the frontier line: the scroll clamps
                            // at the ends of the document, the brightest
                            // line does not move.
                            followAnchorY: followAnchorY,
                            // The measured geometry of the body: the bridge
                            // reads the focus at the reading position from
                            // it (the top of the poem reads at its first
                            // line, its end at its last one).
                            geometry: geometry,
                            userScrolled: state.poemUserScrolled,
                            initialFraction: state.poemUserScrolled ? state.poemReaderOffset : nil,
                            focusController: state.poemFocus,
                            contentKey: contentKey,
                            onHoverChanged: { state.setPoemHover($0, region: .body) },
                            onReaderScrolled: { state.noteUserScroll($0) }) {
            if session.mode == .full {
                PoemBreakView(session: session,
                              font: font,
                              color: model.foregroundColor,
                              spacing: spacing,
                              geometry: geometry,
                              focusController: state.poemFocus)
            } else {
                PoemRevealView(preview: preview,
                               font: font,
                               nsFont: nsFont,
                               color: model.foregroundColor,
                               width: width,
                               spacing: spacing,
                               geometry: geometry,
                               focusController: state.poemFocus)
            }
        }
    }

    /// The identity of a poem body: the hosted poem of the reading viewport
    /// is rebuilt only when it changes, so the focus style always reaches the
    /// hosted tree and a settled scroll position survives the ticks in between.
    /// The dynamic rules (following, contrast, motion) are NOT part of it:
    /// they travel through the focus controller instead.
    private static func poemContentKey(lines: [String], width: CGFloat, height: CGFloat,
                                       fontSize: CGFloat, spacing: CGFloat, full: Bool) -> AnyHashable {
        var hasher = Hasher()
        hasher.combine(lines.joined(separator: "\u{0}"))
        hasher.combine(Int(width.rounded()))
        hasher.combine(Int(height.rounded()))
        hasher.combine(Int(fontSize.rounded()))
        // The spacing is hashed exactly, like the layout cache keys it must
        // agree with: a rounded value would let two nearby multipliers share
        // one hosted poem (and one settled scroll position).
        hasher.combine(spacing)
        hasher.combine(full)
        return AnyHashable(hasher.finalize())
    }

    /// True when the system asks for more contrast: the focus keeps its
    /// hierarchy, but no large near-transparent text stays behind.
    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// True when the system asks for less movement: the focus keeps its
    /// hierarchy, without transition animations or glides.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

/// The measured geometry of a poem body: the layout side of the reading
/// focus. It only changes with the identity of the content (the lines, the
/// width, the face) — it is captured when the hosted poem is built. The
/// dynamic rules live in the focus controller, so the hosted tree reads them
/// live without a rebuild.
struct PoemFocusGeometry: Equatable {
    /// The y of the centre of every line, in document coordinates.
    let centers: [CGFloat]
    /// True for a line that holds words (blank and punctuation-only lines
    /// keep the spacing of the stanzas but are never a focus).
    let hasWords: [Bool]
    /// The height of one row of type.
    let rowUnit: CGFloat
    /// True when the body fits the viewport and every line is clear — the
    /// short complete poem reads as one, without a gradient.
    let uniform: Bool
}

extension PoemFocusGeometry {
    /// The anchor the growing poem reads at: while the follow has it, the
    /// frontier line is the focus — even on the very first frame, when the
    /// reported anchor is still the controller's initial 0 and reading at
    /// it would light the oldest verses first. Only a real review (the
    /// reader actually scrolled, so `following` is false) reads at the
    /// reported position, which follows the slider and the wheel; hovering
    /// never changes it. A frontier outside the laid-out lines falls back
    /// to the reported anchor.
    func revealAnchorY(following: Bool, frontierLine: Int, reportedAnchorY: CGFloat) -> CGFloat {
        guard following, frontierLine >= 0, frontierLine < centers.count else {
            return reportedAnchorY
        }
        return centers[frontierLine]
    }

    /// The reading brightness of every line at the given anchor, under the
    /// given emphasis rules.
    func opacities(anchorY: CGFloat, emphasis: PoemFocusEmphasis) -> [Double] {
        guard !uniform else { return centers.map { _ in 1 } }
        return PoemFocus.opacities(centers: centers.map(Double.init),
                                   hasWords: hasWords,
                                   anchorY: Double(anchorY),
                                   unitHeight: Double(rowUnit),
                                   increaseContrast: emphasis.increaseContrast,
                                   boostedLineOpacity: emphasis.following ? emphasis.boostedLineOpacity : nil,
                                   boostedLines: emphasis.boostedLines)
    }
}

/// The poem of a break: the whole poem, line by line. The reading viewport
/// around it scrolls; this view only draws the lines — each with the
/// brightness its reading distance gives it.
struct PoemBreakView: View {
    let session: PoemBreakSession
    let font: Font
    let color: Color
    /// The spacing between the lines of the poem.
    let spacing: CGFloat
    /// The measured geometry of the body.
    let geometry: PoemFocusGeometry
    /// The focus the scroll bridge reports the reading anchor to.
    @ObservedObject var focusController: PoemFocusController

    var body: some View {
        let emphasis = focusController.emphasis
        let opacities = geometry.opacities(anchorY: focusController.anchorY, emphasis: emphasis)
        VStack(spacing: spacing) {
            ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in
                PoemFocusedLine(text: line,
                                opacity: index < opacities.count ? opacities[index] : 1,
                                font: font, color: color,
                                animate: emphasis.following && !emphasis.reduceMotion)
            }
        }
    }
}

/// One line of a poem at its reading brightness. Only the brightness moves,
/// with a soft handover while the follow moves the focus: the size, the
/// weight and the spacing of the type stay exactly where they are, and a
/// review moves the brightness without any trailing animation.
struct PoemFocusedLine: View {
    let text: String
    let opacity: Double
    let font: Font
    let color: Color
    /// True when the handover between lines animates (the follow, without
    /// reduced motion).
    let animate: Bool

    var body: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .foregroundColor(color.opacity(opacity))
            .animation(animate ? Tween.emphasisHandover : nil, value: opacity)
    }
}

/// The poem of a break while it grows: the revealed text from its beginning
/// through the frontier, with the shared soft edge at the end of the frontier
/// line. The reading viewport around it scrolls; this view only draws the
/// lines — the frontier line is the brightest, the lines before it step back
/// with their reading distance.
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
    /// The measured geometry of the body.
    let geometry: PoemFocusGeometry
    /// The focus the scroll bridge reports the reading anchor to.
    @ObservedObject var focusController: PoemFocusController

    var body: some View {
        let emphasis = focusController.emphasis
        // The growing poem reads at its frontier while the follow has it:
        // the first frame is already bright at the newest words, whatever
        // the reported anchor is; only a real review reads at the position
        // the bridge reported.
        let anchorY = geometry.revealAnchorY(following: emphasis.following,
                                             frontierLine: preview.softEdgeLineIndex,
                                             reportedAnchorY: focusController.anchorY)
        let opacities = geometry.opacities(anchorY: anchorY, emphasis: emphasis)
        VStack(spacing: spacing) {
            ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                if index == preview.softEdgeLineIndex {
                    SoftEdgePoemLine(text: line,
                                     edgeOffset: preview.softEdgeOffset,
                                     font: font,
                                     nsFont: nsFont,
                                     color: color,
                                     lineOpacity: index < opacities.count ? opacities[index] : 1,
                                     availableWidth: width,
                                     animate: emphasis.following && !emphasis.reduceMotion)
                } else {
                    // The lines before the frontier are fully revealed: they
                    // carry no soft edge, only their reading brightness.
                    PoemFocusedLine(text: line,
                                    opacity: index < opacities.count ? opacities[index] : 1,
                                    font: font, color: color,
                                    animate: emphasis.following && !emphasis.reduceMotion)
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
/// the width the text needs and the width of the part before the edge. The
/// line itself sits at its reading brightness: the frontier is the focus, so
/// its line keeps the full brightness and only the soft edge shapes its tail.
struct SoftEdgePoemLine: View {
    let text: String
    /// The character offset where the soft edge starts (the first character of
    /// the first word that belongs to the edge).
    let edgeOffset: Int
    let font: Font
    /// The same face as `font`, measured with CoreText.
    let nsFont: NSFont
    let color: Color
    /// The reading brightness of the line.
    let lineOpacity: Double
    /// The width the line is laid out in.
    let availableWidth: CGFloat
    /// True when the handover between lines animates (the follow, without
    /// reduced motion).
    let animate: Bool

    var body: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .foregroundColor(color.opacity(lineOpacity))
            .frame(maxWidth: .infinity)
            .mask(edgeMask)
            .animation(animate ? Tween.emphasisHandover : nil, value: lineOpacity)
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

/// The areas of the poem whose cursor keeps it visible: the body and the
/// credit report separately, and the poem stays visible while the cursor is
/// on either of them. The clock and the rest of the window are not areas.
enum PoemHoverRegion: Hashable {
    case body
    case credit
}

/// 100 ms tick, mirroring the legacy renderer interval.
final class BreakWindowState: ObservableObject {
    @Published var progressFraction: Double = 1
    /// The opacity of the poem of the break: it fades in, waits and fades
    /// out again, and stays hidden until the break ends. While the cursor
    /// rests on the body or the credit of the poem, the poem stays visible
    /// as one group.
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
    /// The refresh of the poem of this break. It stops when the break ends.
    private var poemTimer: Timer?
    /// True when the poem of this break is gone for good: the break reached
    /// its captured duration, and no hover may call it back.
    private var poemFinished = false
    /// The poem session the reading state belongs to. A rebuilt window (a
    /// display change) starts the same session again and the reading state
    /// survives it; a new break starts a new session and hides the old poem.
    private var poemSession: PoemBreakSession?
    /// The poem areas the cursor is on. Aggregating the areas keeps the leave
    /// of one area from cancelling the enter of the other when the cursor
    /// moves between the body and the credit.
    private var poemHoverRegions: Set<PoemHoverRegion> = []
    /// When the cursor last left all poem areas (nil while it never was on
    /// the poem).
    private var hoverLeftAt: Int64?
    /// When the entry tween of the hover began (nil while none runs): a
    /// hover that calls a hidden or partly faded poem back eases it in over
    /// the shared token instead of snapping it to full opacity.
    private var poemEntryBeganAt: Int64?
    /// The alpha the poem showed when that tween began.
    private var poemEntrySeed: Double = 1
    /// The alpha the poem had reached when the cursor last left all of its
    /// areas: the leave fade decays from there, so a leave during the entry
    /// never flashes the poem to full opacity.
    private var poemLeaveSeedAlpha: Double = 1
    /// True once the reader scrolled in the poem themselves: the poem stays
    /// where they put it — the follow keeps its hands off from then on.
    @Published var poemUserScrolled = false
    /// The reading position the reader scrolled to (0 at the top, 1 at the
    /// newest words): a rebuilt window restores it.
    @Published var poemReaderOffset: Double = 1
    /// The reading focus shared with the viewport bridge: the bridge reports
    /// the reading anchor, the lines read it.
    let poemFocus = PoemFocusController()
    /// True while the poem is read below its first line: the reading area
    /// starts at the end of the poem, so the cut at the top is the rule until
    /// the reader scrolls back to the very first line.
    var poemIsReadBelowItsFirstLine: Bool {
        !poemUserScrolled || poemReaderOffset > 0
    }

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
    /// instead of playing it again, and a poem that is gone for good stays
    /// hidden. The envelope of the complete poem grows with the amount of
    /// text (its reading time), capped by the break.
    ///
    /// When the same captured session starts again, the reading state (the
    /// cursor on the poem, the reading position) survives the rebuild; a new
    /// session hides the old poem and starts from the beginning.
    private func startPoem(model: BreakContentView.Model) {
        let samePoem = model.poem != nil && model.poem == poemSession
        poemTimer?.invalidate()
        poemTimer = nil
        poemTimeline = nil
        poemFinished = false
        if !samePoem {
            poemOpacity = 0
            poemUserScrolled = false
            poemReaderOffset = 1
            poemHoverRegions = []
            hoverLeftAt = nil
            poemEntryBeganAt = nil
            poemEntrySeed = 1
            poemLeaveSeedAlpha = 1
        }
        guard let session = model.poem else {
            poemSession = nil
            return
        }
        poemSession = session
        let timeline: PoemTimeline
        if session.mode == .full {
            timeline = PoemTimeline.full(mini: session.mini, toDuration: model.duration,
                                         wordCount: session.totalWords)
        } else {
            timeline = PoemTimeline.scaled(mini: session.mini, toDuration: model.duration)
        }
        poemTimeline = timeline
        syncPoemFocusEmphasis()
        guard timeline.totalMillis > 0 else { return }
        updatePoem()
        // The poem becomes visible right away: the refresh starts now and
        // stops by itself once nothing changes any more.
        ensurePoemTimer()
    }

    /// The cursor entered or left one poem area (the body or the credit).
    ///
    /// The poem stays visible while the cursor rests on any of its areas and
    /// fades out softly after it left all of them. The cursor is retention
    /// only: it never moves the poem, never changes the reading position and
    /// never changes which line is the brightest. The areas are aggregated,
    /// so moving between the body and the credit keeps the poem visible no
    /// matter in which order the enter and leave events arrive.
    func setPoemHover(_ active: Bool, region: PoemHoverRegion) {
        guard let model = modelRef, model.poem != nil else { return }
        let now = SystemClock().nowMillis
        if active {
            guard !poemHoverRegions.contains(region) else { return }
            poemHoverRegions.insert(region)
            if poemHoverRegions.count == 1 {
                hoverLeftAt = nil
                // A hover that calls a hidden or partly faded poem back
                // eases it in from the alpha on screen right now instead of
                // snapping it to full opacity. Reduced motion restores at
                // once, and a poem already at full strength needs no tween.
                // The union only transitions once per rest on the poem, so
                // moving between the body and the credit never restarts it.
                if !reduceMotion, poemOpacity < 1 {
                    poemEntryBeganAt = now
                    poemEntrySeed = poemOpacity
                }
            }
        } else {
            guard poemHoverRegions.contains(region) else { return }
            poemHoverRegions.remove(region)
            if poemHoverRegions.isEmpty {
                hoverLeftAt = now
                // The leave fade decays from the alpha the poem has reached
                // at this moment: a leave during the entry continues from
                // where the ease stood, never flashing to full opacity.
                poemLeaveSeedAlpha = poemOpacity
                poemEntryBeganAt = nil
            }
        }
        updatePoem()
    }

    /// The reader scrolled in the poem themselves — with the wheel, the
    /// trackpad, the slider, the track or the keyboard; the bridge reports
    /// every one of them through the bounds of the clip view. The poem stays
    /// where they put it: the follow keeps its hands off from then on, so a
    /// reader is never dragged back to a position the clock has computed. The
    /// reading position is kept, so a rebuilt window restores it.
    func noteUserScroll(_ offset: Double) {
        if !poemUserScrolled {
            poemUserScrolled = true
        }
        if poemReaderOffset != offset {
            poemReaderOffset = offset
        }
        syncPoemFocusEmphasis()
    }

    /// The emphasis rules of the focus, synced into the controller whenever
    /// the reading state or the accessibility settings change. It publishes
    /// only a real change and only outside view updates (the timers and the
    /// event handlers call this) — the hosted poem reads the rules live,
    /// without a rebuild and without a scroll reset.
    private func syncPoemFocusEmphasis() {
        guard let session = modelRef?.poem else { return }
        let mark = session.focusMark
        let emphasis = PoemFocusEmphasis(
            following: !poemUserScrolled,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: reduceMotion,
            boostedLineOpacity: mark.secondaryLines.isEmpty ? nil : PoemFocus.newWordLineOpacity,
            boostedLines: mark.secondaryLines)
        if poemFocus.emphasis != emphasis {
            poemFocus.emphasis = emphasis
        }
    }

    /// The high-frequency refresh of the poem. It is started when the poem
    /// can change and stops by itself when nothing changes any more: a
    /// hidden poem is woken by the hover events, and the break deadline is
    /// covered by the low-frequency tick of the break.
    private func ensurePoemTimer() {
        guard poemTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.updatePoem()
        }
        RunLoop.main.add(timer, forMode: .common)
        poemTimer = timer
    }

    private func updatePoem() {
        guard let timeline = poemTimeline, let model = modelRef, model.poem != nil else { return }
        let now = SystemClock().nowMillis
        let elapsed = now - model.started
        if elapsed >= model.duration {
            // The break reached its captured duration: the poem is gone for
            // good, hovered or not — no refresh is needed any more. The review
            // ends with it: a poem that can never come back has no reading
            // position to keep.
            poemFinished = true
            publish(poemOpacity: 0)
            poemEntryBeganAt = nil
            if poemUserScrolled {
                poemUserScrolled = false
            }
            poemTimer?.invalidate()
            poemTimer = nil
            return
        }
        let sinceLeft = hoverLeftAt.map { now - $0 }
        let entry = poemEntryBeganAt.map {
            PoemRetention.Entry(seedAlpha: poemEntrySeed,
                                millisSinceBegan: max(0, now - $0))
        }
        publish(poemOpacity: PoemRetention.opacity(timeline: timeline,
                                                   elapsedMillis: elapsed,
                                                   breakDurationMillis: model.duration,
                                                   hovering: poemHover,
                                                   millisSinceLeft: sinceLeft,
                                                   reduceMotion: reduceMotion,
                                                   entry: entry,
                                                   leaveSeedAlpha: poemLeaveSeedAlpha))
        syncPoemFocusEmphasis()
        // The refresh runs while the poem can still change: while it is
        // visible, or while an entry tween eases a hovered poem back in —
        // that one begins at the alpha it starts from, possibly zero, so it
        // alone has to keep the refresh alive until it has advanced past its
        // first step.
        if poemOpacity > 0 || poemEntryBeganAt != nil {
            ensurePoemTimer()
        } else {
            poemTimer?.invalidate()
            poemTimer = nil
        }
    }

    /// A property that is published only when it really changes: the refresh
    /// of the poem never wakes the window for the same value again.
    private func publish(poemOpacity newValue: Double) {
        if poemOpacity != newValue {
            poemOpacity = newValue
        }
    }

    /// True while the cursor rests on any poem area.
    private var poemHover: Bool {
        !poemHoverRegions.isEmpty
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
        updatePoem()
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
