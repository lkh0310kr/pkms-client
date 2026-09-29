import SwiftUI
import UIKit

/// Commands and state shared between the text view and the SwiftUI chrome around it
/// (formatting bar, "/" menu, page-link suggestions).
@MainActor
@Observable
final class EditorController {
    @ObservationIgnored fileprivate weak var textView: EditorTextView?
    @ObservationIgnored fileprivate var onTextChange: (String) -> Void = { _ in }

    private(set) var suggestion: MarkdownEditing.SuggestionContext?
    private(set) var isFocused = false
    /// Index of the highlighted suggestion; return picks it.
    var highlightedSuggestion = 0

    var text: String { textView?.text ?? "" }

    func focus(atEnd: Bool = false) {
        guard let textView else { return }
        if atEnd { textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0) }
        textView.becomeFirstResponder()
    }

    func dismissKeyboard() { textView?.resignFirstResponder() }
    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }
    var canUndo: Bool { textView?.undoManager?.canUndo ?? false }

    func setBlockStyle(_ style: BlockStyle) {
        apply { MarkdownEditing.setBlockStyle(style, in: $0, selection: $1) }
    }

    func insert(_ block: BlockInsertion) {
        apply { MarkdownEditing.insert(block, in: $0, selection: $1) }
    }

    func toggleWrap(_ marker: String) {
        apply { MarkdownEditing.toggleWrap(marker, in: $0, selection: $1) }
    }

    func insertLink() {
        apply { MarkdownEditing.insertLink(in: $0, selection: $1) }
    }

    /// Starts a `[[` page link at the cursor, which opens page suggestions.
    func startPageLink() {
        apply { _, selection in
            TextEdit(range: selection, replacement: "[[", selection: NSRange(location: selection.location + 2, length: 0))
        }
    }

    /// The "+" button: opens the "/" menu on the current line if it's empty, or on a new line below.
    func openCommandMenu() {
        if !(textView?.isFirstResponder ?? false) { focus() }
        apply { text, selection in
            let ns = text as NSString
            let line = MarkdownEditing.lineRange(in: ns, for: selection)
            let isEmpty = ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
            let insertion = isEmpty ? "/" : "\n/"
            let at = isEmpty ? NSRange(location: line.location, length: line.length) : NSRange(location: line.location + line.length, length: 0)
            return TextEdit(range: at, replacement: insertion,
                            selection: NSRange(location: at.location + insertion.utf16.count, length: 0))
        }
    }

    /// Replaces the whole text (e.g. after merging a change from sync), keeping the cursor nearby.
    func replaceAllText(with newText: String) {
        guard let textView else { return }
        let caret = min(textView.selectedRange.location, (newText as NSString).length)
        replace(TextEdit(range: NSRange(location: 0, length: (textView.text as NSString).length),
                         replacement: newText, selection: NSRange(location: caret, length: 0)))
    }

    func moveSuggestionHighlight(by delta: Int) {
        highlightedSuggestion = max(0, highlightedSuggestion + delta)
    }

    func indent() { apply { MarkdownEditing.indent(in: $0, selection: $1) } }
    func outdent() { apply { MarkdownEditing.outdent(in: $0, selection: $1) } }

    /// Replaces the "/query" trigger with the chosen block style.
    func chooseCommand(_ command: SlashCommand) {
        guard let context = suggestion, context.kind == .command else { return }
        replace(TextEdit(range: context.range, replacement: "",
                         selection: NSRange(location: context.range.location, length: 0)))
        switch command.action {
        case .style(let style): setBlockStyle(style)
        case .insert(let block): insert(block)
        }
    }

    /// Completes a `[[query` trigger with a page name.
    func choosePage(_ name: String) {
        guard let context = suggestion, context.kind == .page else { return }
        let replacement = "[[\(name)]]"
        replace(TextEdit(range: context.range, replacement: replacement,
                         selection: NSRange(location: context.range.location + replacement.utf16.count, length: 0)))
    }

    func cancelSuggestion() { suggestion = nil }

    // MARK: - Internals

    private func apply(_ makeEdit: (String, NSRange) -> TextEdit) {
        guard let textView else { return }
        replace(makeEdit(textView.text, textView.selectedRange))
    }

    /// Applies an edit through `UITextInput` so it participates in undo.
    fileprivate func replace(_ edit: TextEdit) {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end) else { return }
        textView.replace(range, withText: edit.replacement)
        textView.selectedRange = edit.selection
        textDidChange()
    }

    fileprivate func textDidChange() {
        guard let textView else { return }
        onTextChange(textView.text)
        updateSuggestion()
    }

    fileprivate func updateSuggestion() {
        guard let textView else { return }
        let context = textView.isFirstResponder
            ? MarkdownEditing.suggestionContext(in: textView.text, selection: textView.selectedRange)
            : nil
        if context?.kind != suggestion?.kind || context?.query != suggestion?.query { highlightedSuggestion = 0 }
        suggestion = context
    }

    fileprivate func setFocused(_ focused: Bool) {
        isFocused = focused
        updateSuggestion()
    }

    /// Called for return while a suggestion list is showing. Returns true if it handled the key.
    @ObservationIgnored var onSuggestionReturn: () -> Bool = { false }
}

/// An entry in the "/" menu.
struct SlashCommand: Identifiable {
    enum Action {
        case style(BlockStyle)
        case insert(BlockInsertion)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let action: Action

    static let all: [SlashCommand] = [
        SlashCommand(id: "text", title: "Text", subtitle: "Plain paragraph", symbol: "textformat", keywords: ["paragraph", "plain", "본문", "텍스트"], action: .style(.paragraph)),
        SlashCommand(id: "h1", title: "Heading 1", subtitle: "Big section heading", symbol: "number", keywords: ["title", "h1", "제목"], action: .style(.heading(1))),
        SlashCommand(id: "h2", title: "Heading 2", subtitle: "Medium section heading", symbol: "number", keywords: ["h2", "제목"], action: .style(.heading(2))),
        SlashCommand(id: "h3", title: "Heading 3", subtitle: "Small section heading", symbol: "number", keywords: ["h3", "제목"], action: .style(.heading(3))),
        SlashCommand(id: "todo", title: "To-do List", subtitle: "Track tasks with checkboxes", symbol: "checklist", keywords: ["task", "check", "checkbox", "할일", "체크"], action: .style(.todo)),
        SlashCommand(id: "bullet", title: "Bulleted List", subtitle: "Simple bulleted list", symbol: "list.bullet", keywords: ["unordered", "ul", "목록"], action: .style(.bullet)),
        SlashCommand(id: "numbered", title: "Numbered List", subtitle: "List with numbering", symbol: "list.number", keywords: ["ordered", "ol", "번호"], action: .style(.numbered)),
        SlashCommand(id: "quote", title: "Quote", subtitle: "Capture a quote", symbol: "text.quote", keywords: ["blockquote", "인용"], action: .style(.quote)),
        SlashCommand(id: "code", title: "Code", subtitle: "Code block", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["snippet", "코드"], action: .insert(.codeBlock)),
        SlashCommand(id: "divider", title: "Divider", subtitle: "Visually divide blocks", symbol: "minus", keywords: ["line", "hr", "rule", "구분선"], action: .insert(.divider)),
    ]

    static func matching(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { command in
            command.title.lowercased().contains(q) || command.id.hasPrefix(q) || command.keywords.contains { $0.hasPrefix(q) }
        }
    }
}

/// Wraps `UITextView` with live Markdown styling.
struct MarkdownEditorView: UIViewRepresentable {
    let initialText: String
    let controller: EditorController
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> EditorTextView {
        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.editor = controller
        textView.delegate = context.coordinator
        textView.textStorage.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 120, right: 16)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.adjustsFontForContentSizeCategory = true
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.typingAttributes = context.coordinator.highlighter.baseAttributes
        textView.text = initialText
        context.coordinator.highlighter.highlight(textView.textStorage, editedRange: nil, isProcessingEdit: false)
        controller.textView = textView
        controller.onTextChange = onChange
        return textView
    }

    func updateUIView(_ textView: EditorTextView, context: Context) {
        controller.onTextChange = onChange
    }

    final class Coordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate {
        let controller: EditorController
        let highlighter = MarkdownHighlighter()

        init(controller: EditorController) {
            self.controller = controller
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            // The documented place to adjust attributes (not characters) of the edit being processed.
            MainActor.assumeIsolated { highlighter.highlight(storage, editedRange: editedRange, isProcessingEdit: true) }
        }

        func textViewDidChange(_ textView: UITextView) {
            MainActor.assumeIsolated { controller.textDidChange() }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            MainActor.assumeIsolated {
                textView.typingAttributes = highlighter.baseAttributes
                controller.updateSuggestion()
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            MainActor.assumeIsolated { controller.setFocused(true) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            MainActor.assumeIsolated { controller.setFocused(false) }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            MainActor.assumeIsolated {
                guard text == "\n" else { return true }
                if controller.suggestion != nil, controller.onSuggestionReturn() { return false }
                if let edit = MarkdownEditing.returnKey(in: textView.text, selection: range) {
                    controller.replace(edit)
                    return false
                }
                return true
            }
        }
    }
}

/// Adds hardware-keyboard shortcuts (⌘B, ⌘I, ⌘K, tab to indent) on iPad.
final class EditorTextView: UITextView {
    weak var editor: EditorController?

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        if editor?.suggestion != nil {
            for (input, action) in [(UIKeyCommand.inputUpArrow, #selector(suggestionUp)), (UIKeyCommand.inputDownArrow, #selector(suggestionDown))] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands + [
            UIKeyCommand(title: "Bold", action: #selector(bold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(italic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Link", action: #selector(link), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Strikethrough", action: #selector(strike), input: "x", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "To-do", action: #selector(todo), input: "l", modifierFlags: .command),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentLine)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentLine)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
        ]
    }

    @objc private func suggestionUp() { editor?.moveSuggestionHighlight(by: -1) }
    @objc private func suggestionDown() { editor?.moveSuggestionHighlight(by: 1) }
    @objc private func bold() { editor?.toggleWrap("**") }
    @objc private func italic() { editor?.toggleWrap("*") }
    @objc private func link() { editor?.insertLink() }
    @objc private func strike() { editor?.toggleWrap("~~") }
    @objc private func todo() { editor?.setBlockStyle(.todo) }
    @objc private func indentLine() { editor?.indent() }
    @objc private func outdentLine() { editor?.outdent() }
    @objc private func escape() {
        if editor?.suggestion != nil { editor?.cancelSuggestion() } else { resignFirstResponder() }
    }
}
