import Testing
import UIKit
@testable import PKMS

/// Lays text out with the live-preview stack (no view) and checks where things end up.
@MainActor
struct LivePreviewLayoutTests {
    let storage = NSTextStorage()
    let layoutManager = LivePreviewLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
    let highlighter = MarkdownHighlighter(widgets: WidgetCache())

    init() {
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    private func layout(_ text: String, selection: NSRange? = nil) {
        storage.setAttributedString(NSAttributedString(string: text))
        highlighter.highlight(storage, editedRange: nil, selection: selection, isProcessingEdit: false)
        layoutManager.ensureLayout(for: container)
    }

    private func rect(of substring: String) -> CGRect {
        let range = (storage.string as NSString).range(of: substring)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    @Test func checkboxSitsAtLineStartAndTextFollowsIt() {
        layout("- [ ] Milk\n- [ ] Eggs")
        let milk = rect(of: "Milk")
        #expect(rect(of: "- [ ]").minX < 8, "checkbox should start the line")
        #expect(milk.minX > 20 && milk.minX < 40, "text should follow the checkbox, got \(milk)")
        // Every item lines up, not just the first paragraph of the note.
        #expect(abs(rect(of: "Eggs").minX - milk.minX) < 1)
    }

    @Test func wrappedTaskLinesAlignWithText() {
        layout("Intro\n- [ ] " + String(repeating: "word ", count: 30))
        let range = (storage.string as NSString).range(of: "word")
        let firstLine = layoutManager.lineFragmentUsedRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        let last = layoutManager.glyphIndexForCharacter(at: storage.length - 2)
        let lastLineText = layoutManager.boundingRect(forGlyphRange: NSRange(location: layoutManager.glyphRange(forBoundingRect: layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil), in: container).location, length: 1), in: container)
        #expect(lastLineText.minX > 20, "wrapped lines should hang under the text, got \(lastLineText)")
        #expect(firstLine.minY < lastLineText.minY)
    }

    @Test func renderedTableIsFullHeight() throws {
        let table = try #require(MarkdownParser.parse("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |").blocks.first.flatMap {
            if case .table(let table) = $0 { table } else { nil }
        })
        let image = try #require(WidgetCache().table(table, key: "t", dark: false))
        #expect(image.size.height > 4 * 30, "all four rows should be rendered, got \(image.size)")
    }

    @Test func tableReservesItsHeight() {
        let source = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |"
        layout("Intro\n" + source + "\nAfter")
        let intro = rect(of: "Intro")
        let after = rect(of: "After")
        var decoration: MarkdownDecoration?
        storage.enumerateAttribute(.mdDecoration, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let d = value as? MarkdownDecoration, d.isWidget { decoration = d }
        }
        guard case .widget(_, let size)? = decoration?.kind else {
            Issue.record("table should render as a widget")
            return
        }
        #expect(after.minY - intro.maxY >= size.height, "text after the table should start below it")
    }

    @Test func boldItalicHidesAllMarkers() {
        layout("x ***both*** y")
        #expect(rect(of: "both").minX - rect(of: "x").maxX < 12)
    }

    @Test func hiddenHeadingMarkerTakesNoSpace() {
        layout("# Title")
        #expect(rect(of: "Title").minX < 8)
    }
}
