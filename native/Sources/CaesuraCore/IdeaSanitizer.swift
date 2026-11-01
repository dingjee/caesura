import Foundation

/// Sanitizes custom break content. Instead of relying on a browser DOM,
/// ideas are parsed with a strict whitelist into `IdeaNode` trees that the SwiftUI break
/// view renders as AttributedString/images. Nothing else (scripts, styles, event
/// handlers, external images) survives.
public enum IdeaSanitizer {
    public static let allowedTags: Set<String> = ["a", "b", "i", "img", "br", "p", "h1", "h2", "h3"]

    public static func sanitize(_ value: String?) -> [IdeaNode] {
        guard let value, !value.isEmpty else { return [] }
        let prepared = prepareFragment(value)
        guard let wrapped = "<root>\(prepared)</root>".data(using: .utf8) else { return [] }
        let delegate = WhitelistParserDelegate()
        let parser = XMLParser(data: wrapped)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.nodes
    }

    /// XML needs well-formed input; idea HTML may use `<br>` and named entities.
    static func prepareFragment(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br>", with: "<br/>").replacingOccurrences(of: "<br/>", with: "<br/>")
        text = text.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
        // Remove comments and anything inside script/style outright.
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<script[\\s\\S]*?</script>", with: "")
        text = text.replacingOccurrences(of: "(?is)<style[\\s\\S]*?</style>", with: "")
        return text
    }

    // Legacy URI policies from sanitizeIdea.js.
    public static func isAllowedURI(_ uri: String) -> Bool {
        uri.range(of: #"^(?:https:\/\/.+|mailto:.+|[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)$"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isAllowedAnchorURI(_ uri: String) -> Bool {
        uri.range(of: #"^(?:https:\/\/.+|mailto:.+)$"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isAllowedImageFilename(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]+\.(png|jpe?g|webp|gif)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isAllowedAudioFilename(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]+\.wav$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum IdeaNode: Equatable {
    case text(String, bold: Bool, italic: Bool)
    case link(text: String, href: String?, bold: Bool, italic: Bool)
    case image(filename: String, alt: String?, width: Double?, height: Double?)
    case lineBreak
    indirect case block(tag: String, children: [IdeaNode])
}

final class WhitelistParserDelegate: NSObject, XMLParserDelegate {
    var nodes: [IdeaNode] = []
    private var stack: [TagContext] = []
    private var buffer = ""
    private var droppingDepth = 0

    private struct TagContext: Hashable {
        let tag: String
        let bold: Bool
        let italic: Bool
        let href: String?
    }

    private var currentBold: Bool { stack.contains { $0.bold } }
    private var currentItalic: Bool { stack.contains { $0.italic } }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        flushText()
        let tag = elementName.lowercased()
        if tag == "root" { return } // synthetic wrapper
        guard IdeaSanitizer.allowedTags.contains(tag) else {
            droppingDepth += 1
            return
        }
        guard droppingDepth == 0 else { return }
        switch tag {
        case "br":
            append(.lineBreak)
        case "img":
            let src = attributes["src"] ?? ""
            if IdeaSanitizer.isAllowedImageFilename(src) {
                append(.image(filename: src, alt: attributes["alt"],
                              width: attributes["width"].flatMap(Double.init),
                              height: attributes["height"].flatMap(Double.init)))
            }
        case "a":
            var href = attributes["href"]
            if let current = href, !IdeaSanitizer.isAllowedURI(current) || !IdeaSanitizer.isAllowedAnchorURI(current) {
                href = nil
            }
            stack.append(TagContext(tag: tag, bold: currentBold, italic: currentItalic, href: href))
        default:
            stack.append(TagContext(tag: tag, bold: currentBold || tag == "b",
                                    italic: currentItalic || tag == "i", href: nil))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        flushText()
        let tag = elementName.lowercased()
        if tag == "root" { return } // synthetic wrapper
        if droppingDepth > 0 {
            if !IdeaSanitizer.allowedTags.contains(tag) {
                droppingDepth -= 1
            }
            return
        }
        guard let context = stack.popLast() else { return }
        let children = pendingChildren[context] ?? []
        pendingChildren[context] = nil
        switch context.tag {
        case "a":
            append(.link(text: children.map(flatten).joined(), href: context.href,
                         bold: context.bold, italic: context.italic))
        case "p", "h1", "h2", "h3":
            append(.block(tag: context.tag, children: children))
        default:
            // b/i wrappers fold into their children's formatting (already captured).
            children.forEach { append($0) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    private var pendingChildren: [TagContext: [IdeaNode]] = [:]

    private func append(_ node: IdeaNode) {
        if let parent = stack.last {
            pendingChildren[parent, default: []].append(node)
        } else {
            nodes.append(node)
        }
    }

    private func flushText() {
        guard !buffer.isEmpty else { return }
        let text = buffer
        buffer = ""
        if droppingDepth > 0 { return } // text inside a dropped subtree is discarded
        append(.text(text, bold: currentBold, italic: currentItalic))
    }

    private func flatten(_ node: IdeaNode) -> String {
        switch node {
        case .text(let text, _, _): return text
        case .link(let text, _, _, _): return text
        case .lineBreak: return "\n"
        case .image(let filename, _, _, _): return filename
        case .block(_, let children): return children.map(flatten).joined()
        }
    }
}
