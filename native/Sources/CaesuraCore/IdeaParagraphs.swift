import Foundation

/// Groups the nodes of a break idea into the paragraphs of a poem.
///
/// The lines of the poem are kept — they are the breaks of the poem — and a
/// line that ends a sentence closes its paragraph. The break window gives a
/// paragraph a little more room than a line, so the sentence ends are visible.
public enum IdeaParagraphs {
    /// The punctuation that ends a sentence.
    public static let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    /// The paragraphs of the idea: the lines of the poem, grouped by the
    /// sentences they end.
    public static func paragraphs(from nodes: [IdeaNode]) -> [[IdeaNode]] {
        var lines: [[IdeaNode]] = [[]]
        for node in nodes {
            if case .lineBreak = node {
                lines.append([])
            } else {
                lines[lines.count - 1].append(node)
            }
        }
        // A trailing line break leaves an empty line behind.
        while lines.count > 1, lines[lines.count - 1].isEmpty {
            lines.removeLast()
        }

        var paragraphs: [[IdeaNode]] = []
        var current: [IdeaNode] = []
        for (index, line) in lines.enumerated() {
            current.append(contentsOf: line)
            if endsSentence(line) {
                paragraphs.append(current)
                current = []
            } else if index < lines.count - 1 {
                // The lines of a paragraph keep their line break.
                current.append(.lineBreak)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    /// Does the line end a sentence?
    public static func endsSentence(_ line: [IdeaNode]) -> Bool {
        for node in line.reversed() {
            if case .text(let text, _, _) = node {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let last = trimmed.last else { continue }
                return sentenceEndings.contains(last)
            }
        }
        return false
    }
}
