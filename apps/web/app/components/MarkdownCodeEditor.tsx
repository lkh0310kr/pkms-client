import { useEffect, useRef } from "react";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { defaultHighlightStyle, indentOnInput, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { EditorState, RangeSetBuilder, StateEffect, StateField, type Extension } from "@codemirror/state";
import { Decoration, EditorView, keymap, ViewPlugin, WidgetType, type DecorationSet, type ViewUpdate } from "@codemirror/view";

const setHoveredLine = StateEffect.define<number | null>();
const hoveredLine = StateField.define<number | null>({
  create: () => null,
  update(value, transaction) {
    if (transaction.docChanged) return null;
    for (const effect of transaction.effects) if (effect.is(setHoveredLine)) return effect.value;
    return value;
  },
});

const hide = Decoration.replace({});
const headingTypes = new Set(["ATXHeading1", "ATXHeading2", "ATXHeading3", "ATXHeading4", "ATXHeading5", "ATXHeading6"]);

function selectionTouches(state: EditorState, from: number, to: number): boolean {
  return state.selection.ranges.some((range) => range.from <= to && range.to >= from);
}

function revealForPointerOrCaret(view: EditorView, from: number, to: number): boolean {
  if (selectionTouches(view.state, from, to)) return true;
  const hovered = view.state.field(hoveredLine);
  if (hovered === null) return false;
  return hovered >= view.state.doc.lineAt(from).number && hovered <= view.state.doc.lineAt(to).number;
}

function collectInline(view: EditorView): DecorationSet {
  const ranges: { from: number; to: number; decoration: Decoration }[] = [];
  const add = (from: number, to: number, decoration: Decoration) => {
    if (from < to) ranges.push({ from, to, decoration });
  };
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({ from, to, enter(node) {
      const name = node.type.name;
      const raw = revealForPointerOrCaret(view, node.from, node.to);
      if (headingTypes.has(name)) {
        const mark = node.node.getChild("HeaderMark");
        if (!mark) return;
        const contentFrom = mark.to + (view.state.doc.sliceString(mark.to, mark.to + 1) === " " ? 1 : 0);
        const level = name.slice(-1);
        if (contentFrom < node.to) add(contentFrom, node.to, Decoration.mark({ class: `cm-live-heading-text cm-live-h${level}` }));
        if (!raw && contentFrom < node.to) add(mark.from, contentFrom, hide);
        return;
      }
      if (name === "Emphasis" || name === "StrongEmphasis" || name === "Strikethrough") {
        const marks = node.node.getChildren(name === "Strikethrough" ? "StrikethroughMark" : "EmphasisMark");
        if (marks.length !== 2 || marks[0].to >= marks[1].from) return;
        const cls = name === "StrongEmphasis" ? "cm-live-strong" : name === "Strikethrough" ? "cm-live-strike" : "cm-live-em";
        add(marks[0].to, marks[1].from, Decoration.mark({ class: cls }));
        if (!raw) { add(marks[0].from, marks[0].to, hide); add(marks[1].from, marks[1].to, hide); }
        return;
      }
      if (name === "InlineCode") {
        const marks = node.node.getChildren("CodeMark");
        if (marks.length !== 2 || marks[0].to >= marks[1].from) return;
        add(marks[0].to, marks[1].from, Decoration.mark({ class: "cm-live-code" }));
        if (!raw) { add(marks[0].from, marks[0].to, hide); add(marks[1].from, marks[1].to, hide); }
        return;
      }
      if (name === "Link") {
        const marks = node.node.getChildren("LinkMark");
        const url = node.node.getChild("URL");
        if (marks.length < 2 || marks[0].to >= marks[1].from) return;
        add(marks[0].to, marks[1].from, Decoration.mark({ class: "cm-live-link" }));
        if (!raw) {
          add(marks[0].from, marks[0].to, hide);
          add(marks[1].from, Math.min(node.to, url ? url.to + 1 : marks[1].to), hide);
        }
        return;
      }
      if (name === "Blockquote") {
        add(node.from, node.to, Decoration.mark({ class: "cm-live-quote-text" }));
        const mark = node.node.getChild("QuoteMark");
        if (mark && !raw) add(mark.from, mark.to, hide);
        return;
      }
      if (name === "ListItem") {
        if (node.node.getChild("Task")) return;
        const mark = node.node.getChild("ListMark");
        if (mark && !raw) add(mark.from, mark.to, Decoration.replace({ widget: new ListMarker(view.state.doc.sliceString(mark.from, mark.to)) }));
        return;
      }
      if (name === "FencedCode" && !raw) {
        const marks = node.node.getChildren("CodeMark");
        if (marks.length >= 2) {
          const openEnd = view.state.doc.lineAt(marks[0].from).to;
          const closeStart = view.state.doc.lineAt(marks[marks.length - 1].from).from;
          add(marks[0].from, Math.min(openEnd, node.to), hide);
          add(closeStart, marks[marks.length - 1].to, hide);
        }
      }
    }});
  }
  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  for (const range of ranges) builder.add(range.from, range.to, range.decoration);
  return builder.finish();
}

class ListMarker extends WidgetType {
  constructor(readonly marker: string) { super(); }
  eq(other: ListMarker) { return other.marker === this.marker; }
  toDOM() {
    const marker = document.createElement("span");
    marker.className = "cm-live-list-marker";
    marker.textContent = /^\d/.test(this.marker) ? this.marker : "•";
    return marker;
  }
}

const inlineLivePreview = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(readonly view: EditorView) { this.decorations = collectInline(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.transactions.some((transaction) => transaction.effects.some((effect) => effect.is(setHoveredLine)))) {
      this.decorations = collectInline(update.view);
    }
  }
}, { decorations: (plugin) => plugin.decorations });

const blockLivePreview = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(readonly view: EditorView) { this.decorations = this.build(); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.transactions.some((transaction) => transaction.effects.some((effect) => effect.is(setHoveredLine)))) this.decorations = this.build();
  }
  build() {
    const builder = new RangeSetBuilder<Decoration>();
    const lines = new Map<number, string>();
    const addClass = (from: number, className: string) => lines.set(from, `${lines.get(from) ?? ""} ${className}`.trim());
    const view = this.view;
    for (const range of view.visibleRanges) syntaxTree(view.state).iterate({ from: range.from, to: range.to, enter(node) {
      if (node.type.name === "Blockquote") {
        for (const mark of node.node.getChildren("QuoteMark")) addClass(view.state.doc.lineAt(mark.from).from, "cm-live-quote-line");
      }
      if (node.type.name === "FencedCode") {
        const start = view.state.doc.lineAt(node.from).number;
        const end = view.state.doc.lineAt(node.to).number;
        for (let number = start; number <= end; number++) addClass(view.state.doc.line(number).from, "cm-live-code-line");
      }
    }});
    for (const [from, className] of [...lines].sort(([a], [b]) => a - b)) builder.add(from, from, Decoration.line({ class: className }));
    return builder.finish();
  }
}, { decorations: (plugin) => plugin.decorations });

const pointerTracking: Extension = EditorView.domEventHandlers({
  mousemove(event, view) {
    const position = view.posAtCoords({ x: event.clientX, y: event.clientY });
    const line = position === null ? null : view.state.doc.lineAt(position).number;
    if (view.state.field(hoveredLine) !== line) view.dispatch({ effects: setHoveredLine.of(line) });
    return false;
  },
  mouseleave(_event, view) {
    if (view.state.field(hoveredLine) !== null) view.dispatch({ effects: setHoveredLine.of(null) });
    return false;
  },
});

export function MarkdownCodeEditor({ value, onChange, onNavigateReady }: { value: string; onChange: (value: string) => void; onNavigateReady?: (navigate: ((line: number) => void) | null) => void }) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  useEffect(() => {
    if (!host.current) return;
    const state = EditorState.create({
      doc: value,
      extensions: [
        markdown(), history(), indentOnInput(), syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        hoveredLine, inlineLivePreview, blockLivePreview, pointerTracking,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]), EditorView.lineWrapping,
        EditorView.contentAttributes.of({ "aria-label": "Markdown editor", autocapitalize: "sentences", spellcheck: "true" }),
        EditorView.updateListener.of((update) => { if (update.docChanged) onChangeRef.current(update.state.doc.toString()); }),
        EditorView.theme({
          "&": { height: "100%", color: "var(--text)", backgroundColor: "var(--editor)", fontSize: "14px" },
          ".cm-scroller": { overflow: "auto", fontFamily: "var(--editor-font)" },
          ".cm-content": { padding: "24px clamp(18px, 5vw, 64px) 48px", lineHeight: "1.8", caretColor: "var(--text)", maxWidth: "820px", margin: "0 auto" },
          ".cm-gutters": { display: "none" },
          ".cm-activeLine": { backgroundColor: "transparent" },
          ".cm-selectionBackground": { backgroundColor: "var(--selected) !important" },
          ".cm-cursor": { borderLeftColor: "var(--text)" },
        }),
      ],
    });
    const editor = new EditorView({ state, parent: host.current });
    view.current = editor;
    return () => { view.current = null; editor.destroy(); };
  }, []);

  useEffect(() => {
    if (!view.current || !onNavigateReady) return;
    const navigate = (line: number) => {
      const editor = view.current;
      if (!editor) return;
      const position = editor.state.doc.line(Math.max(1, Math.min(line, editor.state.doc.lines))).from;
      editor.dispatch({ selection: { anchor: position }, scrollIntoView: true });
      editor.focus();
    };
    onNavigateReady(navigate);
    return () => onNavigateReady(null);
  }, [onNavigateReady]);

  useEffect(() => {
    const editor = view.current;
    if (!editor || editor.state.doc.toString() === value) return;
    const previous = editor.state.doc.toString();
    let prefix = 0;
    while (prefix < previous.length && prefix < value.length && previous[prefix] === value[prefix]) prefix++;
    let suffix = 0;
    while (suffix < previous.length - prefix && suffix < value.length - prefix && previous[previous.length - suffix - 1] === value[value.length - suffix - 1]) suffix++;
    editor.dispatch({ changes: { from: prefix, to: previous.length - suffix, insert: value.slice(prefix, value.length - suffix) } });
  }, [value]);

  return <div ref={host} className="markdown-code-editor" />;
}
