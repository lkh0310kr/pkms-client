import UIKit

/// Styles Markdown source in place while it's being edited: headings get larger, emphasis looks
/// emphasized, and syntax characters fade back. The text itself is never changed, so the file stays plain Markdown.
@MainActor
final class MarkdownHighlighter {
    private let body = UIFont.preferredFont(forTextStyle: .body)
    private lazy var mono = UIFontMetrics(forTextStyle: .body)
        .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))

    private var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 6
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private let fence = regex(#"^[ \t]*(```|~~~).*$"#)
    private let heading = regex(#"^(#{1,6})([ \t]+)(.*)$"#)
    private let quote = regex(#"^([ \t]*>[ \t]?)(.*)$"#)
    private let task = regex(#"^([ \t]*[-*+] \[([ xX])\] )(.*)$"#)
    private let listMarker = regex(#"^[ \t]*([-*+]|\d{1,9}[.)]) "#)
    private let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private let italic = regex(#"(?<![*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#)
    private let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private let code = regex(#"(`+)([^`\n]+?)\1"#)
    private let link = regex(#"(!?\[)([^\]\n]+)(\]\([^)\n]*\))"#)
    private let wikiLink = regex(#"(!?\[\[)([^\]\n]+)(\]\])"#)

    /// Restyles the paragraphs around `editedRange` (or everything if a code fence changed).
    func highlight(_ storage: NSTextStorage, editedRange: NSRange?, isProcessingEdit: Bool) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var range = full
        if let editedRange, text.length > 5_000 {
            range = text.paragraphRange(for: NSIntersectionRange(editedRange, full))
            if text.substring(with: range).contains("```") || text.substring(with: range).contains("~~~") { range = full }
        }

        if !isProcessingEdit { storage.beginEditing() }
        storage.setAttributes(baseAttributes, range: range)
        let fences = codeBlockRanges(in: text)
        for block in fences where NSIntersectionRange(block, range).length > 0 {
            let r = NSIntersectionRange(block, range)
            storage.addAttributes([.font: mono, .backgroundColor: UIColor.secondarySystemBackground], range: r)
        }
        func outsideCode(_ r: NSRange) -> Bool { !fences.contains { NSIntersectionRange($0, r).length > 0 } }
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                if let match, outsideCode(match.range) { body(match) }
            }
        }

        each(heading) { m in
            let level = (text.substring(with: m.range(at: 1)) as NSString).length
            storage.addAttribute(.font, value: headingFont(level), range: m.range)
            dim(storage, NSUnionRange(m.range(at: 1), m.range(at: 2)))
        }
        each(quote) { m in
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: m.range(at: 2))
            dim(storage, m.range(at: 1))
        }
        each(listMarker) { m in
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: m.range(at: 1))
        }
        each(task) { m in
            dim(storage, m.range(at: 1))
            if text.substring(with: m.range(at: 2)) != " " {
                storage.addAttributes([.foregroundColor: UIColor.secondaryLabel,
                                       .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 3))
            }
        }
        each(rule) { m in dim(storage, m.range) }
        each(bold) { m in
            addTraits(.traitBold, storage, m.range(at: 2))
            dim(storage, m.range(at: 1)); dim(storage, NSRange(location: m.range.upperBound - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        each(italic) { m in
            addTraits(.traitItalic, storage, m.range(at: 2))
            dim(storage, m.range(at: 1)); dim(storage, NSRange(location: m.range.upperBound - 1, length: 1))
        }
        each(strike) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            dim(storage, NSRange(location: m.range.location, length: 2)); dim(storage, NSRange(location: m.range.upperBound - 2, length: 2))
        }
        each(link) { m in
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: m.range(at: 2))
            dim(storage, m.range(at: 1)); dim(storage, m.range(at: 3))
        }
        each(wikiLink) { m in
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: m.range(at: 2))
            dim(storage, m.range(at: 1)); dim(storage, m.range(at: 3))
        }
        each(code) { m in
            storage.addAttributes([.font: mono, .backgroundColor: UIColor.secondarySystemFill], range: m.range)
            dim(storage, m.range(at: 1)); dim(storage, NSRange(location: m.range.upperBound - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        if !isProcessingEdit { storage.endEditing() }
    }

    private func headingFont(_ level: Int) -> UIFont {
        let (size, weight): (CGFloat, UIFont.Weight) = switch level {
        case 1: (30, .bold)
        case 2: (24, .bold)
        case 3: (20, .semibold)
        default: (17, .semibold)
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range)
    }

    private func addTraits(_ traits: UIFontDescriptor.SymbolicTraits, _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? UIFont) ?? body
            if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: subrange)
            }
        }
    }

    /// Ranges of fenced code blocks, including their fence lines. An unclosed fence runs to the end.
    private func codeBlockRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var open: NSRange?
        fence.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            if let start = open {
                ranges.append(NSUnionRange(start, match.range))
                open = nil
            } else {
                open = match.range
            }
        }
        if let open { ranges.append(NSRange(location: open.location, length: text.length - open.location)) }
        return ranges
    }
}
