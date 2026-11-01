import Foundation

/// Assembles the break-window HTML for a poem.
///
/// A Mini break shows the short excerpt, a Long break the full poem under its
/// title. The author is a line of its own (not part of the poem text): the
/// break window sets it close under the poem. Output goes through
/// `IdeaSanitizer` (`br`/`i` are allowed), so text must be XML-escaped here.
public enum PoemIdeaFormatter {
    /// The excerpt of a Mini break: the lines of the poem, without the author.
    public static func miniBody(_ poem: Poem) -> String {
        poem.excerpt.map { escape($0) }.joined(separator: "<br>")
    }

    /// The author line. It is a line of its own (not part of the poem text):
    /// the break window sets it close under the poem, upright after the author.
    public static func author(_ poem: Poem) -> String {
        let name = escape(poem.author)
        guard !name.isEmpty else { return "" }
        return "— \(name)"
    }

    public static func longTitle(_ poem: Poem) -> String {
        escape(poem.title)
    }

    /// The lines of a Long break. Empty `lines` entries are stanza breaks;
    /// joined with `<br>` they render as a blank line between stanzas.
    public static func longBody(_ poem: Poem) -> String {
        poem.lines.map { escape($0) }.joined(separator: "<br>")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
