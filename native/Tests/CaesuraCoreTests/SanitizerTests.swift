import Foundation
import CaesuraCore

enum SanitizerTests {
    static func registerAll() {
        TestRunner.register("sanitizer: plain text passthrough", plainText)
        TestRunner.register("sanitizer: allowed tags b/i/br/p/h1", allowedTags)
        TestRunner.register("sanitizer: script content dropped", scriptDropped)
        TestRunner.register("sanitizer: anchor href policy", anchors)
        TestRunner.register("sanitizer: image filename policy", images)
        TestRunner.register("sanitizer: nested formatting", nested)
    }

    static func plainText() throws {
        let nodes = IdeaSanitizer.sanitize("Just stretch a bit.")
        try expectEqual(nodes, [.text("Just stretch a bit.", bold: false, italic: false)])
        try expectEqual(IdeaSanitizer.sanitize(nil).count, 0)
        try expectEqual(IdeaSanitizer.sanitize("").count, 0)
    }

    static func allowedTags() throws {
        let nodes = IdeaSanitizer.sanitize("<b>bold</b> and <i>slanted</i><br/>next")
        try expectEqual(nodes.count, 5)
        try expectEqual(nodes[0], .text("bold", bold: true, italic: false))
        try expectEqual(nodes[1], .text(" and ", bold: false, italic: false))
        try expectEqual(nodes[2], .text("slanted", bold: false, italic: true))
        try expectEqual(nodes[3], .lineBreak)
        try expectEqual(nodes[4], .text("next", bold: false, italic: false))
        let blocks = IdeaSanitizer.sanitize("<p>one</p><h2>two</h2>")
        try expectEqual(blocks.count, 2)
        try expectEqual(blocks[0], .block(tag: "p", children: [.text("one", bold: false, italic: false)]))
        try expectEqual(blocks[1], .block(tag: "h2", children: [.text("two", bold: false, italic: false)]))
    }

    static func scriptDropped() throws {
        let nodes = IdeaSanitizer.sanitize("ok<script>alert(1)</script>fine")
        try expectEqual(nodes, [.text("ok", bold: false, italic: false), .text("fine", bold: false, italic: false)])
        let commented = IdeaSanitizer.sanitize("a<!-- hidden -->b")
        try expectEqual(commented, [.text("ab", bold: false, italic: false)])
    }

    static func anchors() throws {
        let good = IdeaSanitizer.sanitize(#"<a href="https://example.org">link</a>"#)
        try expectEqual(good, [.link(text: "link", href: "https://example.org", bold: false, italic: false)])
        let mailto = IdeaSanitizer.sanitize(#"<a href="mailto:x@y.z">mail</a>"#)
        try expectEqual(mailto[0], .link(text: "mail", href: "mailto:x@y.z", bold: false, italic: false))
        // javascript: and local-file anchors lose their href but keep the text
        let evil = IdeaSanitizer.sanitize(#"<a href="javascript:alert(1)">click</a>"#)
        try expectEqual(evil, [.link(text: "click", href: nil, bold: false, italic: false)])
        let relative = IdeaSanitizer.sanitize(#"<a href="some/relative.path">rel</a>"#)
        try expectEqual(relative[0], .link(text: "rel", href: nil, bold: false, italic: false))
    }

    static func images() throws {
        let good = IdeaSanitizer.sanitize(#"<img src="stretch.png" alt="demo">"#)
        try expectEqual(good, [.image(filename: "stretch.png", alt: "demo", width: nil, height: nil)])
        let external = IdeaSanitizer.sanitize(#"<img src="https://evil.example/x.png">"#)
        try expectEqual(external.count, 0)
        let traversal = IdeaSanitizer.sanitize(#"<img src="../secrets.png">"#)
        try expectEqual(traversal.count, 0)
    }

    static func nested() throws {
        let nodes = IdeaSanitizer.sanitize("<p>stay <b><i>hydrated</i></b></p>")
        try expectEqual(nodes.count, 1)
        try expectEqual(nodes[0], .block(tag: "p", children: [
            .text("stay ", bold: false, italic: false),
            .text("hydrated", bold: true, italic: true)
        ]))
    }
}
