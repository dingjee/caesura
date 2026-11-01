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
        let reading = PoemReadingView(poem: poem, imagesDirectory: directory)
            .environment(\.colorScheme, .light)
            .frame(width: 620, height: 560)
            .background(Color.white)
        write(image: reading, to: directory.appendingPathComponent("poem-window.png"))

        var cases: [[String: Any]] = []
        for (name, session) in sessions() {
            let preview = session.preview
            let lines = session.mode == .full ? session.lines : preview.lines
            // The body of the poem is measured, as the window measures it.
            let budget = height * 0.38
            let spacing = height * 0.012
            let layout = PoemBodyLayoutResolver.resolve(
                lines: lines,
                natural: BreakTypography.size(.body, forHeight: height),
                width: width,
                height: budget,
                spacing: spacing,
                font: { size in
                    BreakTypography.serifFont(size: size, weight: .medium, italic: true)
                })
            let viewport = min(layout.contentHeight, budget)
            let poemView: AnyView
            if session.mode == .full {
                // The complete poem: every line, without a soft edge.
                poemView = AnyView(PoemBreakView(session: session,
                                                 font: BreakTypography.serif(size: layout.fontSize,
                                                                             weight: .medium,
                                                                             italic: true),
                                                 color: .white,
                                                 width: width,
                                                 spacing: spacing,
                                                 viewportHeight: viewport,
                                                 contentHeight: layout.contentHeight,
                                                 offset: 0,
                                                 fadesTop: layout.overflows))
            } else {
                poemView = AnyView(PoemRevealView(preview: preview,
                                                   font: BreakTypography.serif(size: layout.fontSize,
                                                                               weight: .medium,
                                                                               italic: true),
                                                   nsFont: BreakTypography.serifFont(size: layout.fontSize,
                                                                                 weight: .medium,
                                                                                 italic: true),
                                                   color: .white,
                                                   width: width,
                                                   spacing: spacing,
                                                   viewportHeight: viewport,
                                                   contentHeight: layout.contentHeight,
                                                   offset: max(0, layout.contentHeight - viewport),
                                                   fadesTop: layout.overflows))
            }
            let view = ZStack {
                Color(red: 0.28, green: 0.52, blue: 0.52)
                poemView.frame(width: width, height: height)
            }
            write(image: view, to: directory.appendingPathComponent("\(name).png"))

            // The whole break window with the poem and the clock.
            let state = BreakWindowState()
            state.poemOpacity = 1
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
                .frame(width: 900, height: 600)
            write(image: content, to: directory.appendingPathComponent("\(name)-break.png"))

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
                                     availableWidth: width)
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
        let summary: [String: Any] = ["cases": cases]
        if let data = try? JSONSerialization.data(withJSONObject: summary,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            try? text.write(to: directory.appendingPathComponent("probe.json"), atomically: true, encoding: .utf8)
        }
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
