import { useEffect, useRef } from "react";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { defaultHighlightStyle, indentOnInput, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { Compartment, EditorState, type Range } from "@codemirror/state";
import { Decoration, EditorView, keymap, ViewPlugin, type DecorationSet, type ViewUpdate } from "@codemirror/view";

const livePreview = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(readonly view: EditorView) { this.decorations = this.build(); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged) this.decorations = this.build();
  }
  build(): DecorationSet {
    const hidden: Range<Decoration>[] = [];
    const styled: Range<Decoration>[] = [];
    const activeLines = new Set(this.view.state.selection.ranges.map((range) => this.view.state.doc.lineAt(range.head).number));
    const addMark = (from: number, to: number) => {
      if (this.view.state.doc.lineAt(from).number === this.view.state.doc.lineAt(to).number && !activeLines.has(this.view.state.doc.lineAt(from).number)) {
        hidden.push(Decoration.replace({}).range(from, to));
      }
    };
    for (const { from, to } of this.view.visibleRanges) {
      syntaxTree(this.view.state).iterate({ from, to, enter: (node) => {
        const name = node.type.name;
        if (["ATXHeading1", "ATXHeading2", "ATXHeading3", "ATXHeading4", "ATXHeading5", "ATXHeading6", "SetextHeading1", "SetextHeading2"].includes(name)) {
          const level = name.match(/Heading([1-6])/)?.[1] ?? "2";
          styled.push(Decoration.line({ class: `cm-live-heading cm-live-heading-${level}` }).range(node.from));
        } else if (name === "Emphasis") styled.push(Decoration.mark({ class: "cm-live-emphasis" }).range(node.from, node.to));
        else if (name === "StrongEmphasis") styled.push(Decoration.mark({ class: "cm-live-strong" }).range(node.from, node.to));
        else if (name === "InlineCode") styled.push(Decoration.mark({ class: "cm-live-code" }).range(node.from, node.to));
        else if (name === "Link") styled.push(Decoration.mark({ class: "cm-live-link" }).range(node.from, node.to));
        else if (name === "Blockquote") styled.push(Decoration.line({ class: "cm-live-quote" }).range(node.from));
        else if (name === "ListItem") {
          const marker = node.node.getChild("ListMark");
          const markerText = marker ? this.view.state.doc.sliceString(marker.from, marker.to) : "•";
          styled.push(Decoration.line({ class: "cm-live-list-item", attributes: { "data-marker": markerText } }).range(node.from));
        }
        if (name === "URL" && node.node.parent?.name === "Link") addMark(node.from, node.to);
        if (["HeaderMark", "QuoteMark", "ListMark", "LinkMark", "EmphasisMark", "CodeMark"].includes(name)) addMark(node.from, node.to);
      }});
    }
    hidden.sort((a, b) => a.from - b.from || a.to - b.to);
    styled.sort((a, b) => a.from - b.from || a.to - b.to);
    return Decoration.set([...styled, ...hidden], true);
  }
}, { decorations: (plugin) => plugin.decorations });

export function MarkdownCodeEditor({ value, onChange, mode = "live" }: { value: string; onChange: (value: string) => void; mode?: "live" | "source" | "read" }) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const modeCompartment = useRef(new Compartment());
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  useEffect(() => {
    if (!host.current) return;
    const state = EditorState.create({
      doc: value,
      extensions: [
        markdown(), history(), indentOnInput(), syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        modeCompartment.current.of(mode === "live" ? livePreview : []),
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
    view.current?.dispatch({ effects: modeCompartment.current.reconfigure(mode === "live" ? livePreview : []) });
  }, [mode]);

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
