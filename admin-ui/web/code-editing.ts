// コードブロックの中の書き味。
//
// **エディタの中でコードを書く時に、素の textarea と同じでは困る。**
// 括弧が閉じない、Tab で字下げできない、行末に飛べない。
//
// ここで足す物:
//   - `(` `{` `[` `"` `'` ` を打つと閉じる方も入り、間にカーソルが残る
//   - 閉じる方を打った時、すぐ右が同じ文字なら**重ねずに乗り越える**
//   - 括弧の間で Backspace すると両方消える
//   - Tab で字下げ、Shift+Tab で戻す（選んでいる行はまとめて）
//   - Enter で前の行の字下げを引き継ぐ
//   - Ctrl+E で行末、Ctrl+A で行頭（macOS の慣れに合わせる）
//
// **どれもコードブロックの中だけ。** 本文では Tab は次の欄へ移る物なので奪わない。

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";

const PAIRS: Record<string, string> = {
  "(": ")",
  "[": "]",
  "{": "}",
  '"': '"',
  "'": "'",
  "`": "`",
};

const CLOSERS = new Set(Object.values(PAIRS));

const INDENT = "  ";

type Where = { inCode: boolean; from: number; to: number };

function place(state: { selection: { $from: { parent: { type: { name: string } } }; from: number; to: number } }): Where {
  return {
    inCode: state.selection.$from.parent.type.name === "codeBlock",
    from: state.selection.from,
    to: state.selection.to,
  };
}

// 今の行の頭と末尾（コードブロックの中の位置）。
function lineOf(text: string, at: number): { start: number; end: number } {
  const start = text.lastIndexOf("\n", Math.max(at - 1, 0)) + 1;
  const nextBreak = text.indexOf("\n", at);
  return { start, end: nextBreak === -1 ? text.length : nextBreak };
}

export const CodeEditing = Extension.create({
  name: "codeEditing",

  addKeyboardShortcuts() {
    const inCode = () => this.editor.isActive("codeBlock");

    // 選んでいる行をまとめて字下げする / 戻す。
    const shift = (out: boolean) => () => {
      if (!inCode()) return false;
      const { state, view } = this.editor;
      const { $from, from, to } = state.selection;
      const block = $from.parent;
      const blockStart = $from.start();
      const text = block.textContent;
      const head = lineOf(text, from - blockStart).start;
      const tail = lineOf(text, to - blockStart).end;
      const lines = text.slice(head, tail).split("\n");
      const moved = lines
        .map((line) => (out ? line.replace(new RegExp("^" + INDENT), "") : INDENT + line))
        .join("\n");
      if (moved === text.slice(head, tail)) return true;
      const tr = state.tr.insertText(moved, blockStart + head, blockStart + tail);
      const grew = moved.length - (tail - head);
      tr.setSelection(TextSelection.create(tr.doc, from + (out ? Math.max(grew, -INDENT.length) : INDENT.length), to + grew));
      view.dispatch(tr);
      return true;
    };

    // 行の頭と末尾へ。
    const toEdge = (end: boolean) => () => {
      if (!inCode()) return false;
      const { state, view } = this.editor;
      const { $from, from } = state.selection;
      const blockStart = $from.start();
      const line = lineOf($from.parent.textContent, from - blockStart);
      const at = blockStart + (end ? line.end : line.start);
      view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, at)));
      return true;
    };

    return {
      Tab: shift(false),
      "Shift-Tab": shift(true),
      "Ctrl-e": toEdge(true),
      "Ctrl-a": toEdge(false),

      // 前の行の字下げを引き継ぐ。開いた括弧の直後なら 1 段深くする。
      Enter: () => {
        if (!inCode()) return false;
        const { state, view } = this.editor;
        const { $from, from } = state.selection;
        const blockStart = $from.start();
        const text = $from.parent.textContent;
        const at = from - blockStart;
        const line = lineOf(text, at);
        const indent = (text.slice(line.start, line.end).match(/^[ \t]*/) ?? [""])[0];
        const opened = /[([{]$/.test(text.slice(line.start, at).trimEnd());
        const closesNext = PAIRS[text[at - 1] ?? ""] === text[at];

        if (opened && closesNext) {
          // **閉じる方は下の行に落とす**（どの編集器もこうする）。
          const middle = "\n" + indent + INDENT;
          const tr = state.tr.insertText(middle + "\n" + indent, from, state.selection.to);
          tr.setSelection(TextSelection.create(tr.doc, from + middle.length));
          view.dispatch(tr.scrollIntoView());
          return true;
        }

        view.dispatch(
          state.tr.insertText("\n" + indent + (opened ? INDENT : ""), from, state.selection.to).scrollIntoView()
        );
        return true;
      },

      // 括弧の間なら両方消す。
      Backspace: () => {
        if (!inCode()) return false;
        const { state, view } = this.editor;
        const { $from, from, to } = state.selection;
        if (from !== to) return false;
        const blockStart = $from.start();
        const text = $from.parent.textContent;
        const at = from - blockStart;
        const left = text[at - 1];
        const right = text[at];
        if (left && right && PAIRS[left] === right) {
          view.dispatch(state.tr.delete(from - 1, from + 1));
          return true;
        }
        return false;
      },
    };
  },

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey("codeBrackets"),
        props: {
          handleTextInput(view, from, to, typed) {
            const at = place(view.state);
            if (!at.inCode) return false;
            const closer = PAIRS[typed];
            const next = view.state.doc.textBetween(to, to + 1);

            // 閉じる方を打った時、すぐ右が同じなら重ねずに乗り越える。
            if (CLOSERS.has(typed) && next === typed && from === to) {
              view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, to + 1)));
              return true;
            }

            if (!closer) return false;

            // 引用符は、語の途中では閉じない（`don't` を壊さない）。
            const prev = view.state.doc.textBetween(Math.max(from - 1, 0), from);
            if ((typed === '"' || typed === "'" || typed === "`") && /[A-Za-z0-9]/.test(prev)) return false;

            const tr = view.state.tr.insertText(typed + closer, from, to);
            tr.setSelection(TextSelection.create(tr.doc, from + 1));
            view.dispatch(tr);
            return true;
          },
        },
      }),
    ];
  },
});
