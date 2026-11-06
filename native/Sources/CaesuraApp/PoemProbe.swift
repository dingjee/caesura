import AppKit
import SwiftUI
import CaesuraCore

/// Opt-in probe of the poem of a break (development only).
///
/// The probe renders the poem of a break into an image and writes the image
/// (together with the measured pixels) into a directory. It is started with
/// `CAESURA_POEM_PROBE=<directory>`; without the variable nothing runs and
/// the app starts as usual. The probe writes into the given directory only: it
/// never touches the settings, the user data or the display of an
/// installation.
enum PoemProbe {
    /// The poem of the probe: the same words every time, so that the images
    /// can be compared with each other.
    static let poem = Poem(id: "probe", title: "Hope", author: "Emily Dickinson",
                           lines: ["Hope is the thing with feathers",
                                   "That perches in the soul",
                                   "And sings the tune without the words,"],
                           excerpt: ["Hope is the thing with feathers"],
                           seasons: [], months: [], authorBorn: nil, authorDied: nil,
                           source: "probe")

    private static let width: CGFloat = 900
    private static let height: CGFloat = 600
    private static let background = NSColor(red: 0.28, green: 0.52, blue: 0.52, alpha: 1)

    /// The three situations of a break: a Mini break that reveals the first
    /// word, a Long break that reveals four words and the complete poem.
    private static func sessions() -> [(String, PoemBreakSession)] {
        [
            ("revealing-mini",
             PoemBreakSession.revealing(poem: poem, mini: true, startedAt: 0,
                                       durationMillis: 3_000, revealedBefore: 0)),
            ("revealing-long",
             PoemBreakSession.revealing(poem: poem, mini: false, startedAt: 0,
                                       durationMillis: 5_000, revealedBefore: 0)),
            ("full",
             PoemBreakSession.complete(poem: poem, mini: false, startedAt: 0,
                                       durationMillis: 5_000))
        ]
    }

    /// Renders the probe when it is asked for. Returns true when the probe ran
    /// (the app stops afterwards).
    @MainActor
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CAESURA_POEM_PROBE"],
              !path.isEmpty else { return false }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        render(directory: directory)
        return true
    }

    @MainActor
    private static func render(directory: URL) {
        let font = BreakTypography.serif(.body, height: height, weight: .medium, italic: true)
        let nsFont = BreakTypography.serifFont(.body, height: height, weight: .medium, italic: true)

        // The reading window with the whole poem.
        let reading = PoemReadingView(poem: poem, imagesDirectory: directory,
                                         lineSpacingFactor: PoemSpacing.defaultFactor)
            .environment(\.colorScheme, .light)
            .frame(width: 620, height: 560)
            .background(Color.white)
        write(image: reading, to: directory.appendingPathComponent("poem-window.png"))

        var cases: [[String: Any]] = []
        for (name, session) in sessions() {
            let preview = session.preview
            let lines = session.mode == .full ? session.lines : preview.lines
            // The body of the poem is measured, as the window measures it: the
            // type keeps its size and a longer body becomes a longer scroll.
            let budget = height * 0.38
            let spacing = height * 0.012
            let layout = PoemBodyLayoutResolver.natural(
                lines: lines,
                natural: BreakTypography.size(.body, forHeight: height),
                width: width,
                height: budget,
                spacing: spacing,
                font: { size in
                    BreakTypography.serifFont(size: size, weight: .medium, italic: true)
                })
            let viewport = min(layout.contentHeight, budget)
            let centers = layout.lineCenters(spacing: spacing)
            let mark = session.focusMark
            let frontierCenter = mark.frontierLine >= 0 && mark.frontierLine < centers.count
                ? centers[mark.frontierLine] : nil
            // The probe reads at the follow anchor, like the window: a
            // growing poem focuses the frontier line, the complete poem the
            // line the travel starts at.
            let anchorY = frontierCenter ?? centers.first ?? 0
            let focusController = PoemFocusController()
            focusController.anchorY = anchorY
            focusController.emphasis = PoemFocusEmphasis(
                following: true,
                increaseContrast: false,
                reduceMotion: true,
                boostedLineOpacity: mark.secondaryLines.isEmpty ? nil : PoemFocus.newWordLineOpacity,
                boostedLines: mark.secondaryLines)
            let geometry = PoemFocusGeometry(
                centers: centers,
                hasWords: lines.map { PoemWords.hasWords(in: $0) },
                rowUnit: PoemFocus.rowUnit(heights: layout.lineHeights.map(Double.init)),
                uniform: session.mode == .full && !layout.overflows)
            let poemFont = BreakTypography.serif(size: layout.fontSize, weight: .medium, italic: true)
            let poemNsFont = BreakTypography.serifFont(size: layout.fontSize, weight: .medium, italic: true)
            let poemView: AnyView
            if session.mode == .full {
                // The complete poem: every line, without a soft edge.
                poemView = AnyView(PoemViewport(width: width,
                                                height: viewport,
                                                contentHeight: layout.contentHeight,
                                                offset: 0,
                                                fadesTop: false) {
                    PoemBreakView(session: session, font: poemFont, color: .white,
                                  spacing: spacing, geometry: geometry,
                                  focusController: focusController)
                })
            } else {
                poemView = AnyView(PoemViewport(width: width,
                                                height: viewport,
                                                contentHeight: layout.contentHeight,
                                                offset: max(0, layout.contentHeight - viewport),
                                                fadesTop: layout.overflows) {
                    PoemRevealView(preview: preview, font: poemFont, nsFont: poemNsFont,
                                   color: .white, width: width, spacing: spacing,
                                   geometry: geometry, focusController: focusController)
                })
            }
            let view = ZStack {
                Color(red: 0.28, green: 0.52, blue: 0.52)
                poemView.frame(width: width, height: height)
            }
            write(image: view, to: directory.appendingPathComponent("\(name).png"))

            // The whole break window with the poem and the clock.
            let state = BreakWindowState()
            state.poemOpacity = 1
            // The reading anchor of the follow: the hosted poem shows the
            // same focus the window gives it.
            let bodyLayout = PoemBodyLayoutResolver.natural(
                lines: lines,
                natural: BreakTypography.size(.body, forHeight: height),
                width: width * 0.9,
                height: height * 0.38,
                spacing: height * 0.012,
                font: { size in
                    BreakTypography.serifFont(size: size, weight: .medium, italic: true)
                })
            let bodyCenters = bodyLayout.lineCenters(spacing: height * 0.012)
            if let focusLine = mark.frontierLine >= 0 && mark.frontierLine < bodyCenters.count
                ? mark.frontierLine : bodyCenters.indices.last {
                state.poemFocus.anchorY = bodyCenters[focusLine]
            }
            // The action of the break: the button shows its glyph.
            state.canPostpone = true
            let model = BreakContentView.Model(
                mini: session.mini,
                ideaMini: "",
                ideaLongTitle: "",
                ideaLongText: "",
                started: 0,
                // A Long break lasts five minutes: its ring is much bigger
                // than the button of the short break.
                duration: session.mini ? 20_000 : 300_000,
                miniDuration: 20_000,
                strictMode: false,
                postponable: false,
                postponableDurationPercent: 30,
                backgroundColor: Color(red: 0.28, green: 0.52, blue: 0.52),
                foregroundColor: .white,
                danger: 0,
                breakHealthMode: false,
                themeColor: "#478484",
                blank: false,
                showClock: true,
                clockFontSize: 28,
                clockFormat: "tt",
                shortcutHint: "",
                localization: Localization(),
                imagesDirectory: directory,
                poem: session)
            let content = BreakContentView(state: state, model: model,
                                          onPostpone: {}, onFinish: {})
            // The reading viewport of the break window is an AppKit bridge: it
            // renders inside a real hosting view, not in an image renderer.
            write(hosted: content, size: CGSize(width: 900, height: 600),
                  to: directory.appendingPathComponent("\(name)-break.png"))

            // The frontier line alone: its pixels show the soft edge.
            var ink: [Double] = []
            var edgeStartX = -1.0
            var edgeWidth = -1.0
            if preview.softEdgeLineIndex >= 0, preview.softEdgeLineIndex < preview.lines.count {
                let line = preview.lines[preview.softEdgeLineIndex]
                let lineView = ZStack {
                    Color(red: 0.28, green: 0.52, blue: 0.52)
                    SoftEdgePoemLine(text: line, edgeOffset: preview.softEdgeOffset,
                                     font: font, nsFont: nsFont, color: .white,
                                     lineOpacity: 1,
                                     availableWidth: width,
                                     animate: false)
                        .frame(width: width, height: 120)
                }
                ink = write(image: lineView, to: directory.appendingPathComponent("\(name)-line.png"))
                let edge = PoemSoftEdgeGeometry.edge(text: line, edgeOffset: preview.softEdgeOffset,
                                                     nsFont: nsFont, availableWidth: width)
                edgeStartX = edge?.startX ?? -1
                edgeWidth = edge?.width ?? -1
            }

            cases.append([
                "name": name,
                "kind": session.kind.rawValue,
                "mode": session.mode.rawValue,
                "lines": preview.lines,
                "softEdgeLineIndex": preview.softEdgeLineIndex,
                "softEdgeOffset": preview.softEdgeOffset,
                "textEndOffset": preview.textEndOffset,
                "revealedAfter": session.revealedAfter,
                "totalWords": session.totalWords,
                "poemId": session.poemId,
                "edgeStartX": edgeStartX,
                "edgeWidth": edgeWidth,
                "ink": ink
            ])
        }
        let summary: [String: Any] = ["cases": cases,
                                      "bridge": bridgeProbe(directory: directory),
                                      "viewport": viewportProbe(),
                                      "spacing": spacingProbe(),
                                      "focus": focusProbe(directory: directory),
                                      "reveal": RevealProbe.run()]
        if let data = try? JSONSerialization.data(withJSONObject: summary,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            try? text.write(to: directory.appendingPathComponent("probe.json"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: The bridge probe

    /// A few quiet assertions about the scroll bridge, run offscreen: the
    /// probe creates a scroll view in a window that is never ordered in, so
    /// nothing shows, nothing activates and no pointer moves. It checks the
    /// data path the native slider, the track, the keyboard and the wheel all
    /// share — the bounds of the clip view — against the follow moves.
    @MainActor
    private static func bridgeProbe(directory: URL) -> [String: Any] {
        let controller = PoemFocusController()
        let scroll = PoemScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.focusController = controller
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        // A window that never shows: the deferred syncs only run when the
        // view has one.
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 300, height: 200),
                              styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        // Offscreen the scroll view never tiles: give the clip view its real
        // visible size, as the layout of a live window would.
        scroll.contentView.setBoundsSize(NSSize(width: 300, height: 200))

        var readerEvents: [Double] = []
        scroll.onReaderScrolled = { readerEvents.append($0) }

        // The measured geometry of the shown poem: ten rows of 100 points in a
        // document of 1000 points, every one of them with words. The bridge
        // reads the focus at the reading position from it: the first row at
        // the top of the poem, the last one at its end.
        let probeCenters: [CGFloat] = (0..<10).map { CGFloat($0) * 100 + 50 }
        scroll.focusGeometry = PoemFocusGeometry(
            centers: probeCenters,
            hasWords: Array(repeating: true, count: probeCenters.count),
            rowUnit: 100,
            uniform: false)
        let firstLineCenter = probeCenters.first ?? 0
        let lastLineCenter = probeCenters.last ?? 0

        // The focus of a growing poem locks on the frontier line: even when
        // the scroll would clamp and could never place it at the anchor.
        scroll.lockedFollowAnchorY = 700

        // Let the deferred syncs of the mounting layout run: mounting is no
        // review.
        pumpMainRunLoop(seconds: 0.2)
        let mountEvents = readerEvents.count

        // 1. The follow move is no reader scroll, and the locked anchor wins
        //    over the mapped position of the scroll (500 + 0.65 * 200 = 630).
        scroll.follow(to: NSPoint(x: 0, y: 500))
        pumpMainRunLoop(seconds: 0.2)
        let followAnchor = controller.anchorY

        // 2. The same position again — and a bare layout pass — report
        //    nothing at all, and the same anchor is not published twice.
        scroll.follow(to: NSPoint(x: 0, y: 500))
        scroll.layoutSubtreeIfNeeded()
        pumpMainRunLoop(seconds: 0.2)
        let repeatEvents = readerEvents.count

        // 3. A reader move through the shared bounds path (the native slider,
        //    the track, the keyboard and the wheel all land here) reports
        //    once, with the focus at the reading position: a tenth of the way
        //    through the poem (100 of 800 points of travel).
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        pumpMainRunLoop(seconds: 0.2)
        let reviewAnchor = controller.anchorY
        let reviewEvents = readerEvents.count
        let reviewBounds = String(NSStringFromPoint(scroll.contentView.bounds.origin))

        // 4. A second reader move reports again (a review is continuous).
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 140))
        pumpMainRunLoop(seconds: 0.2)
        let continuousEvents = readerEvents.count

        // 5. The top of the poem reads at its first line, its end at its last
        //    one — the same mapping for the reader and for the travel.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        pumpMainRunLoop(seconds: 0.2)
        let topAnchor = controller.anchorY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        pumpMainRunLoop(seconds: 0.2)
        let bottomAnchor = controller.anchorY

        // 6. The elastic overscroll past the end of the poem clamps: the focus
        //    stays at the last line.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        pumpMainRunLoop(seconds: 0.2)
        let overscrollAnchor = controller.anchorY
        let overscrollBounds = String(NSStringFromPoint(scroll.contentView.bounds.origin))

        // 7. A complete poem (no frontier to lock on) reads at the same
        //    mapping: half way through the poem is the middle of it.
        scroll.lockedFollowAnchorY = nil
        scroll.follow(to: NSPoint(x: 0, y: 400))
        pumpMainRunLoop(seconds: 0.2)
        let travelAnchor = controller.anchorY

        // 6. The drawing of the custom scroller, offscreen, in both system
        //    styles. The scroller view itself is rendered with
        //    `cacheDisplay` — no drawing method is called directly. The
        //    legacy style draws steadily; the overlay style must be accepted
        //    with the subclass installed (never demoted to legacy) and its
        //    render is measured the same way.
        func renderScroller(_ scroller: NSScroller, png: URL?) -> [String: Any] {
            guard scroller.bounds.width >= 4, scroller.bounds.height >= 8,
                  let rep = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else {
                return ["measured": false,
                        "bounds": NSStringFromRect(scroller.bounds)]
            }
            scroller.cacheDisplay(in: scroller.bounds, to: rep)
            if let png { write(rep: rep, to: png) }
            // The scroller's own coordinate mapping is not mirrored by hand
            // (its flipped-ness and the bitmap scale made that unreliable):
            // the ink itself is classified. A capsule thumb is a compact
            // ink blob — never a track the height of the scroller — and its
            // first and last rows are much narrower than its widest row.
            var firstRow = -1
            var lastRow = -1
            var firstWidth = 0
            var lastWidth = 0
            var widest = 0
            var totalInk = 0
            for y in 0..<rep.pixelsHigh {
                var rowMin = -1
                var rowMax = -1
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.1 else { continue }
                    if rowMin < 0 { rowMin = x }
                    rowMax = x
                }
                guard rowMin >= 0 else { continue }
                let width = rowMax - rowMin + 1
                totalInk += width
                if firstRow < 0 {
                    firstRow = y
                    firstWidth = width
                }
                lastRow = y
                lastWidth = width
                widest = max(widest, width)
            }
            if totalInk == 0 {
                // The overlay style at rest: the native fade hides the whole
                // scroller, so nothing at all is drawn — no track residue.
                return ["measured": true, "inkPresent": false]
            }
            return ["measured": true,
                    "inkPresent": true,
                    "trackClear": lastRow - firstRow + 1 <= rep.pixelsHigh / 2,
                    "thumbInkPresent": totalInk >= 20,
                    "thumbEndsRounded": firstWidth <= widest * 3 / 4
                        && lastWidth <= widest * 3 / 4]
        }

        scroll.verticalScroller = PoemScroller()
        var scrollerDrawing: [String: Any] = [
            "overlayCompatible": PoemScroller.isCompatibleWithOverlayScrollers
        ]
        scroll.scrollerStyle = .legacy
        scroll.layoutSubtreeIfNeeded()
        // An unorderable offscreen window can leave the legacy scroller
        // untiled: tile explicitly, and give the measurement the frame the
        // tile would have set.
        scroll.tile()
        scroll.reflectScrolledClipView(scroll.contentView)
        if let scroller = scroll.verticalScroller, scroller.bounds.width < 4 {
            let width = PoemScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            scroller.frame = NSRect(x: scroll.bounds.width - width, y: 0,
                                    width: width, height: scroll.bounds.height)
        }
        if let scroller = scroll.verticalScroller {
            scrollerDrawing["legacy"] = renderScroller(
                scroller,
                png: directory.appendingPathComponent("scroller-capsule.png"))
        }
        scroll.scrollerStyle = .overlay
        scroll.layoutSubtreeIfNeeded()
        scrollerDrawing["overlayAccepted"] = scroll.scrollerStyle == .overlay
            && scroll.verticalScroller is PoemScroller
        if let scroller = scroll.verticalScroller {
            scrollerDrawing["overlay"] = renderScroller(scroller, png: nil)
        }

        let checks: [String: Any] = [
            "boundsChangesSeen": scroll.boundsChangeCount,
            "reportsRan": scroll.reportCount,
            "boundsAfterFollow": String(NSStringFromPoint(scroll.contentView.bounds.origin)),
            "reviewBounds": reviewBounds,
            "mountWasReaderFree": mountEvents == 0,
            "followWasReaderFree": repeatEvents == 0,
            "followAnchor": Double(followAnchor),
            "followAnchorExpected": 700.0,
            "followAnchorIsTheLockedFrontier": followAnchor != 630,
            "reviewReportedOnce": reviewEvents == 1,
            "reviewFraction": readerEvents.first ?? -1,
            "reviewFractionExpected": 100.0 / 800.0,
            "reviewAnchor": Double(reviewAnchor),
            // The focus follows the reading position: a tenth of the way
            // through the poem is a tenth of the way between its first and
            // its last line with words.
            "reviewAnchorExpected": Double(firstLineCenter)
                + (Double(lastLineCenter) - Double(firstLineCenter)) * 0.125,
            "reviewMovesContinuously": continuousEvents == 2,
            // The top of the poem reads at its first line, its end at its
            // last one.
            "topAnchor": Double(topAnchor),
            "topAnchorExpected": Double(firstLineCenter),
            "bottomAnchor": Double(bottomAnchor),
            "bottomAnchorExpected": Double(lastLineCenter),
            // The elastic overscroll past the end clamps at the last line.
            "overscrollBounds": overscrollBounds,
            "overscrollAnchor": Double(overscrollAnchor),
            "overscrollAnchorExpected": Double(lastLineCenter),
            // The travel of the complete poem reads at the same mapping.
            "travelAnchor": Double(travelAnchor),
            "travelAnchorExpected": Double(firstLineCenter)
                + (Double(lastLineCenter) - Double(firstLineCenter)) * 0.5,
            "scroller": scrollerDrawing,
        ]
        window.close()
        return checks
    }

    // MARK: The viewport probe

    /// The model of a break that shows the given complete poem — the same
    /// shape the rendering cases of this probe use.
    @MainActor
    private static func breakModel(session: PoemBreakSession,
                                   started: Int64 = 0,
                                   duration: Int64 = 300_000,
                                   directory: URL) -> BreakContentView.Model {
        BreakContentView.Model(
            mini: session.mini,
            ideaMini: "",
            ideaLongTitle: "",
            ideaLongText: "",
            started: started,
            duration: duration,
            miniDuration: 20_000,
            strictMode: false,
            postponable: false,
            postponableDurationPercent: 30,
            backgroundColor: Color(red: 0.28, green: 0.52, blue: 0.52),
            foregroundColor: .white,
            danger: 0,
            breakHealthMode: false,
            themeColor: "#478484",
            blank: false,
            showClock: true,
            clockFontSize: 28,
            clockFormat: "tt",
            shortcutHint: "",
            localization: Localization(),
            imagesDirectory: directory,
            poem: session)
    }

    /// The reading area of the poem starts at the end of the document, in
    /// both modes: the slider of the viewport stands at the bottom and the
    /// newest words are the ones that are read. The probe hosts the real
    /// bridge offscreen (the hosting view is never ordered in, nothing shows,
    /// no pointer moves) and reads the scroll position it settled on.
    ///
    /// The long last line matters: a frontier that wraps over a large part of
    /// the viewport must not lift the reading area away from the end of the
    /// document.
    @MainActor
    private static func viewportProbe() -> [String: Any] {
        /// A poem whose last line wraps over several rows: the frontier of a
        /// growing poem and the end of a complete one sit in a tall line.
        let wrappingPoem = Poem(id: "probe-viewport", title: "Viewport", author: "Probe",
                                lines: ["A short first line rests at the top",
                                        "A second line rests below it",
                                        String(repeating: "A very long line that wraps over many rows and fills the reading area ", count: 6)],
                                excerpt: [], seasons: [], months: [],
                                authorBorn: nil, authorDied: nil, source: "probe")
        // The frontier of the growing poem sits as late as possible: in the
        // tall last line, and the poem is still growing (it is not complete).
        let total = PoemWords.count(in: wrappingPoem.lines)
        let before = max(0, total - PoemReveal.budget(mini: false) - 1)
        let revealing = PoemBreakSession.revealing(poem: wrappingPoem, mini: false,
                                                    startedAt: 0, durationMillis: 300_000,
                                                    revealedBefore: before)
        let complete = PoemBreakSession.complete(poem: wrappingPoem, mini: false,
                                                  startedAt: 0, durationMillis: 300_000)

        /// The scroll position the reading area settled on, and the anchor it
        /// reported, for one session.
        func settled(session: PoemBreakSession) -> (origin: Double, anchor: Double, maxY: Double) {
            let lines = session.mode == .full ? session.lines : session.preview.lines
            let spacing: CGFloat = 200 * 0.012
            let layout = PoemBodyLayoutResolver.natural(
                lines: lines,
                natural: BreakTypography.size(.body, forHeight: 200),
                width: 180,
                height: 200 * 0.38,
                spacing: spacing,
                font: { size in BreakTypography.serifFont(size: size, weight: .medium, italic: true) })
            let viewport = min(layout.contentHeight, 200 * 0.38)
            let maxOffset = max(0, layout.contentHeight - viewport)
            let controller = PoemFocusController()
            let geometry = PoemFocusGeometry(
                centers: layout.lineCenters(spacing: spacing),
                hasWords: lines.map { PoemWords.hasWords(in: $0) },
                rowUnit: PoemFocus.rowUnit(heights: layout.lineHeights.map(Double.init)),
                uniform: false)
            let frontier = session.focusMark.frontierLine
            let centers = layout.lineCenters(spacing: spacing)
            let anchorY: CGFloat? = session.mode == .full ? nil
                : (frontier >= 0 && frontier < centers.count ? centers[frontier] : nil)
            let root = PoemScrollViewport(width: 180,
                                          height: viewport,
                                          contentHeight: layout.contentHeight,
                                          followOffset: maxOffset,
                                          followAnchorY: anchorY,
                                          geometry: geometry,
                                          userScrolled: false,
                                          initialFraction: nil,
                                          focusController: controller,
                                          contentKey: "probe-\(session.mode.rawValue)",
                                          content: { Color.clear })
            let hosting = NSHostingView(rootView: root.frame(width: 180, height: viewport))
            hosting.frame = NSRect(origin: .zero, size: CGSize(width: 180, height: viewport))
            // The bridge only reports when it lives in a window: the window
            // is never ordered in, so nothing shows and nothing is activated.
            let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 180, height: viewport),
                                  styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            pumpMainRunLoop(seconds: 0.3)
            var origin = 0.0
            var maxY = 0.0
            if let scroll = findScrollView(in: hosting) {
                origin = Double(scroll.contentView.bounds.origin.y)
                maxY = Double(max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))
            }
            let anchor = Double(controller.anchorY)
            window.close()
            return (origin, anchor, maxY)
        }

        let revealingSettled = settled(session: revealing)
        let completeSettled = settled(session: complete)
        // The complete poem reads at its last line: the anchor of the reading
        // position at the end of the document is the last line with words.
        let completeLines = complete.lines
        let completeLayout = PoemBodyLayoutResolver.natural(
            lines: completeLines,
            natural: BreakTypography.size(.body, forHeight: 200),
            width: 180,
            height: 200 * 0.38,
            spacing: 200 * 0.012,
            font: { size in BreakTypography.serifFont(size: size, weight: .medium, italic: true) })
        let completeCenters = completeLayout.lineCenters(spacing: 200 * 0.012)
        let lastLineCenter = completeCenters.last ?? 0
        return [
            "revealingMode": revealing.mode.rawValue,
            "revealingOrigin": revealingSettled.origin,
            "revealingMaxOffset": revealingSettled.maxY,
            "revealingStartsAtTheEnd": abs(revealingSettled.origin - revealingSettled.maxY) < 1,
            "revealingAnchor": revealingSettled.anchor,
            "completeOrigin": completeSettled.origin,
            "completeMaxOffset": completeSettled.maxY,
            "completeStartsAtTheEnd": abs(completeSettled.origin - completeSettled.maxY) < 1,
            "completeAnchor": completeSettled.anchor,
            "completeAnchorExpected": Double(lastLineCenter),
            "completeReadsItsLastLine": abs(completeSettled.anchor - lastLineCenter) < 1,
        ]
    }

    /// The scroll view of a hosted tree (the reading bridge), if there is one.
    @MainActor
    private static func findScrollView(in view: NSView) -> PoemScrollView? {
        if let scroll = view as? PoemScrollView { return scroll }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: The spacing probe

    /// The body layout never rounds the spacing away: two nearby multipliers
    /// whose spacing shares one rounded value (8.76 and 9.49 both round to 9)
    /// must still be two different measurements — a cache hit on the rounded
    /// key would hand the layout of one multiplier to the other, and the
    /// drawn stack would disagree with the measured scroll height. Run
    /// offscreen, through the real cache path of the resolver.
    @MainActor
    private static func spacingProbe() -> [String: Any] {
        let lines = ["A first line to measure at width",
                     "A second line to measure below it",
                     "A third line to measure at the end"]
        let natural = BreakTypography.size(.body, forHeight: height)
        let font = { (size: CGFloat) in
            BreakTypography.serifFont(size: size, weight: .medium, italic: true)
        }
        // The base spacing of the window is 7.3: the default multiplier and
        // the next slider step land 8.76 and 9.49 — the same rounded 9.
        let small = PoemBodyLayoutResolver.natural(
            lines: lines, natural: natural, width: width, height: height,
            spacing: 7.3 * 1.2, font: font)
        let large = PoemBodyLayoutResolver.natural(
            lines: lines, natural: natural, width: width, height: height,
            spacing: 7.3 * 1.3, font: font)
        // The heights the resolver has to produce: every block measured at
        // the width, plus the exact spacing between the blocks, plus the
        // slack the resolver keeps free (see `PoemBodyLayoutResolver`).
        let blocks = lines.map {
            NSAttributedString(string: $0, attributes: [.font: font(natural)])
        }
        let wrapped = PoemBodyMetrics.heights(of: blocks, width: width)
        func expected(_ spacing: CGFloat) -> CGFloat {
            wrapped.reduce(0, +) + spacing * CGFloat(max(0, blocks.count - 1)) + 2
        }
        func isExact(_ layout: PoemBodyLayout, spacing: CGFloat) -> Bool {
            abs(layout.contentHeight - expected(spacing)) < 0.001
        }
        return [
            "smallSpacing": Double(7.3 * 1.2),
            "largeSpacing": Double(7.3 * 1.3),
            "nearbySpacingsMeasureDifferentHeights":
                small.contentHeight != large.contentHeight,
            "smallSpacingMeasuredExactly": isExact(small, spacing: 7.3 * 1.2),
            "largeSpacingMeasuredExactly": isExact(large, spacing: 7.3 * 1.3),
        ]
    }

    // MARK: The focus probe

    /// The reading focus of the growing poem, checked offscreen without a
    /// window: the first frame must already read at the frontier (the
    /// controller starts at anchorY 0, and reading at it would light the
    /// oldest verses first), hovering must never move the focus, a real
    /// scroll must hand the reading position over, and the quiet entry
    /// (JTL) must give it straight back to the frontier. The scroll side
    /// of the same rules is already the bridge probe's review and resume
    /// checks above.
    @MainActor
    private static func focusProbe(directory: URL) -> [String: Any] {
        // A poem long enough that its frontier sits below the first lines:
        // the render cases' probe poem starts at its first line, where the
        // frontier and the oldest verse are the same line.
        let longPoem = Poem(id: "probe-focus", title: "Focus", author: "Probe",
                            lines: ["An older verse rests above the frontier",
                                    "A second older verse rests up there",
                                    "A third older verse rests up there",
                                    "A fourth older verse rests up there",
                                    "The newest words arrive below them",
                                    "And one more line waits at the end"],
                            excerpt: [], seasons: [], months: [],
                            authorBorn: nil, authorDied: nil, source: "probe")
        let session = PoemBreakSession.revealing(poem: longPoem, mini: false,
                                                 startedAt: 0, durationMillis: 5_000,
                                                 revealedBefore: PoemWords.count(in: longPoem.lines) / 2)
        let preview = session.preview
        let frontier = preview.softEdgeLineIndex
        let spacing: CGFloat = height * 0.012
        let layout = PoemBodyLayoutResolver.natural(
            lines: preview.lines,
            natural: BreakTypography.size(.body, forHeight: height),
            width: width,
            height: height * 0.38,
            spacing: spacing,
            font: { size in BreakTypography.serifFont(size: size, weight: .medium, italic: true) })
        let geometry = PoemFocusGeometry(
            centers: layout.lineCenters(spacing: spacing),
            hasWords: preview.lines.map { PoemWords.hasWords(in: $0) },
            rowUnit: PoemFocus.rowUnit(heights: layout.lineHeights.map(Double.init)),
            uniform: false)
        // The controller of a fresh frame: reported anchor still 0, the
        // follow still has the poem.
        let controller = PoemFocusController()

        // The first frame reads at the frontier: the newest line is the
        // brightest and the oldest verse above it is not.
        let pendingAnchor = geometry.revealAnchorY(following: true,
                                                   frontierLine: frontier,
                                                   reportedAnchorY: controller.anchorY)
        let opacities = geometry.opacities(anchorY: pendingAnchor, emphasis: controller.emphasis)
        let frontierOpacity = frontier >= 0 && frontier < opacities.count ? opacities[frontier] : -1
        let firstLineOpacity = opacities.first ?? -1
        let frontierLeadsOnFirstFrame = frontier > 0
            && frontier < geometry.centers.count
            && pendingAnchor == geometry.centers[frontier]
            && frontierOpacity >= 1
            && firstLineOpacity < frontierOpacity

        // Hover is retention, never focus: nothing about the reading focus
        // changes while the cursor rests on the poem or leaves it.
        let state = BreakWindowState()
        let model = breakModel(session: PoemBreakSession.complete(poem: longPoem, mini: false,
                                                                  startedAt: 0,
                                                                  durationMillis: 300_000),
                               started: SystemClock().nowMillis - 1_000,
                               directory: directory)
        state.start(model: model)
        pumpMainRunLoop(seconds: 0.2)
        let hoverAnchorBefore = state.poemFocus.anchorY
        let hoverFollowingBefore = state.poemFocus.emphasis.following
        let hoverOffsetBefore = state.poemReaderOffset
        let hoverScrolledBefore = state.poemUserScrolled
        state.setPoemHover(true, region: .body)
        let hoverKeepsRetention = state.poemOpacity > 0
        state.setPoemHover(false, region: .body)
        let hoverMovesNoFocus = state.poemFocus.anchorY == hoverAnchorBefore
            && state.poemFocus.emphasis.following == hoverFollowingBefore
        // The cursor moves nothing: the reading position and the state of
        // the review stay exactly what they were.
        let hoverMovesNoReadingPosition = state.poemReaderOffset == hoverOffsetBefore
            && state.poemUserScrolled == hoverScrolledBefore

        // A real scroll hands the reading position over: the follow stands
        // down and the review reads at the scrolled position (the bridge
        // probe reports the exact review anchor of that position).
        state.noteUserScroll(0.4)
        let scrollTakesTheReview = state.poemUserScrolled
            && state.poemReaderOffset == 0.4
            && !state.poemFocus.emphasis.following
        state.stop()

        return [
            "frontierLine": frontier,
            "firstFrameAnchor": Double(pendingAnchor),
            "frontierLeadsOnFirstFrame": frontierLeadsOnFirstFrame,
            "firstLineOpacityWhileFollowing": firstLineOpacity,
            "frontierOpacityWhileFollowing": frontierOpacity,
            "hoverKeepsRetention": hoverKeepsRetention,
            "hoverMovesNoFocus": hoverMovesNoFocus,
            "hoverMovesNoReadingPosition": hoverMovesNoReadingPosition,
            "scrollTakesTheReview": scrollTakesTheReview,
        ]
    }

    /// Runs the main run loop briefly so the deferred syncs of the bridge
    /// fire, like they do between the passes of a live window.
    @MainActor
    static func pumpMainRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Writes a rendered bitmap as a PNG.
    private static func write(rep: NSBitmapImageRep, to url: URL) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    /// Writes the image of a view hosted in a real hosting view and returns
    /// the ink of every column (see `write(image:to:)`).
    @MainActor
    @discardableResult
    private static func write(hosted view: some View, size: CGSize, to url: URL) -> [Double] {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return []
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return [] }
        try? png.write(to: url, options: .atomic)
        return inkProfile(rep)
    }

    /// Writes the image and returns the ink of every column: the strongest
    /// contrast against the background, normalized to the contrast of the text.
    @MainActor
    @discardableResult
    private static func write(image view: some View, to url: URL) -> [Double] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return [] }
        try? png.write(to: url, options: .atomic)
        return inkProfile(rep)
    }

    /// The ink of every column of the image.
    @MainActor
    @discardableResult
    private static func inkProfile(_ rep: NSBitmapImageRep) -> [Double] {
        guard let bg = background.usingColorSpace(.deviceRGB) else { return [] }
        let full = max(abs(1.0 - bg.redComponent), abs(1.0 - bg.greenComponent), abs(1.0 - bg.blueComponent))
        var profile = [Double](repeating: 0, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            var best = 0.0
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = max(abs(color.redComponent - bg.redComponent),
                                   abs(color.greenComponent - bg.greenComponent),
                                   abs(color.blueComponent - bg.blueComponent))
                best = max(best, distance)
            }
            profile[x] = full > 0 ? best / full : 0
        }
        return profile
    }
}
