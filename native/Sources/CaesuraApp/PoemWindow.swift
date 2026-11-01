import AppKit
import SwiftUI
import CaesuraCore

/// The window with the poem of the rotation in full.
///
/// It is the quiet way to read the whole poem: the window never opens by
/// itself, it does not start a break, and reading the poem does not count a
/// showing — the poem is only shown by the breaks.
struct PoemWindowView: View {
    let poem: Poem
    let imagesDirectory: URL

    var body: some View {
        ScrollView {
            PoemReadingView(poem: poem, imagesDirectory: imagesDirectory)
        }
    }
}

/// The content of the reading window: the whole poem, its name and
/// its author.
struct PoemReadingView: View {
    let poem: Poem
    let imagesDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 21, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text(author)
                .font(.system(size: 14, design: .serif))
                .foregroundColor(.secondary)
            Divider()
            Text(verses)
                .font(.system(size: 17, design: .serif))
                .italic()
                .lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// The name of the poem.
    private var title: String {
        plain(PoemIdeaFormatter.longTitle(poem))
    }

    /// The author of the poem, on a line of its own.
    private var author: String {
        plain(PoemIdeaFormatter.author(poem))
    }

    /// The verses of the poem; the line breaks and the stanza breaks of the
    /// poem are kept.
    private var verses: String {
        plain(PoemIdeaFormatter.longBody(poem))
    }

    /// The plain text of a formatted poem part. The formatter escapes the text
    /// for the XML based sanitizer, so the text has to travel through it to
    /// lose the escapes again.
    private func plain(_ html: String) -> String {
        let rendered = IdeaTextBuilder.render(nodes: IdeaSanitizer.sanitize(html),
                                              imagesDirectory: imagesDirectory)
        return String(rendered.attributed.characters)
    }
}
