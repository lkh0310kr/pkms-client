import { useEffect, useRef } from "react";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { defaultHighlightStyle, indentOnInput, syntaxHighlighting } from "@codemirror/language";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";

export function MarkdownCodeEditor({ value, onChange }: { value: string; onChange: (value: string) => void }) {
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
