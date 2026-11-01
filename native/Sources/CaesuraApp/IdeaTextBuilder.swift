import SwiftUI
import CaesuraCore

/// Converts sanitized IdeaNodes into SwiftUI-renderable pieces (AttributedString +
/// local images). Links are opened by the app layer (NSWorkspace), never by a web view.
///
/// The runs carry emphasis as `inlinePresentationIntent` (bold/italic) instead of
/// explicit fonts: an explicit run font (.body/.title) would override the base
/// font and size of the surrounding Text, so the type scale of the break window
/// would not apply to the idea anymore.
enum IdeaTextBuilder {
    struct Rendered {
        var attributed: AttributedString
        var images: [ImageRef]
    }

    struct ImageRef: Identifiable {
        let id = UUID()
        var filename: String
        var alt: String?
        var width: Double?
        var height: Double?
        var url: URL?
    }

    static func render(nodes: [IdeaNode], imagesDirectory: URL) -> Rendered {
        var result = Rendered(attributed: AttributedString(), images: [])
        for node in nodes {
            append(node: node, to: &result, imagesDirectory: imagesDirectory)
        }
        return result
    }

    private static func emphasis(bold: Bool, italic: Bool) -> InlinePresentationIntent? {
        var intent: InlinePresentationIntent = []
        if bold { intent.insert(.stronglyEmphasized) }
        if italic { intent.insert(.emphasized) }
        return intent.isEmpty ? nil : intent
    }

    private static func append(node: IdeaNode, to result: inout Rendered, imagesDirectory: URL) {
        switch node {
        case .text(let text, let bold, let italic):
            var attributed = AttributedString(text)
            if let intent = emphasis(bold: bold, italic: italic) {
                attributed.inlinePresentationIntent = intent
            }
            result.attributed += attributed
        case .link(let text, let href, let bold, let italic):
            var attributed = AttributedString(text)
            if let intent = emphasis(bold: bold, italic: italic) {
                attributed.inlinePresentationIntent = intent
            }
            attributed.underlineStyle = .single
            attributed.foregroundColor = .accentColor
            if let href, let url = URL(string: href) {
                attributed.link = url
            }
            result.attributed += attributed
        case .image(let filename, let alt, let width, let height):
            let url = imagesDirectory.appendingPathComponent(filename)
            let ref = ImageRef(filename: filename, alt: alt, width: width, height: height,
                               url: FileManager.default.fileExists(atPath: url.path) ? url : nil)
            result.images.append(ref)
        case .lineBreak:
            result.attributed += AttributedString("\n")
        case .block(let tag, let children):
            switch tag {
            case "h1", "h2", "h3":
                // Headings are emphasized in place; the size stays in the type
                // scale of the break window (no .title override).
                var attributed = render(children: children, imagesDirectory: imagesDirectory).attributed
                for run in attributed.runs {
                    let existing = run.inlinePresentationIntent ?? []
                    attributed[run.range].inlinePresentationIntent = existing.union(.stronglyEmphasized)
                }
                result.attributed += attributed
            default:
                let inner = render(children: children, imagesDirectory: imagesDirectory)
                result.attributed += inner.attributed
                result.images.append(contentsOf: inner.images)
            }
        }
    }

    private static func render(children: [IdeaNode], imagesDirectory: URL) -> Rendered {
        var result = Rendered(attributed: AttributedString(), images: [])
        for child in children {
            append(node: child, to: &result, imagesDirectory: imagesDirectory)
        }
        return result
    }
}
