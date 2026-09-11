// 掛けた装飾から抜ける道。
//
// **付ける道は全部あるのに、外す道が無い所がある。** マークの右端に立ったカーソルは
// ProseMirror の既定では「マークの中」で、そこから打った文字はマークに入り続ける。
// 段落を変えても掛かったままで、下線を掛けた段落の次の段落まで下線になる。
//
// ここで足す 3 つ:
//   - Enter で新しい段落を作った時、掛かっているマークを落とす（リストの項目では残す）
//   - マークの右端で ArrowRight を押すと、カーソルを動かさずにマークから出る
//   - マークの右端で Space を 2 回続けると、2 つ目の Space がマークの外に入る
//
// 抜ける道は 3 つ（ArrowRight / Space 2 回 / ツールバーのボタンをもう一度）。
// **打っている流れを止めないのが Space 2 回**、**打ち終わってから動かすのが ArrowRight**。
//
// WhyNot: TipTap の `exitable` に任せない。**持っているのは `code` だけ**で、`math`・下線・
// 蛍光ペン・上付き・下付きには無い（`web/math.ts` の `MathMark` も持っていない）。その上
// `Mark.handleExit` は `$from.pos === $from.end()` でしか動かないので、**文字を選んで
// ツールバーで掛けた直後（選択の左端が `$from`）には効かない**。抜けた印に空白も 1 つ打つ。
//
// WhyNot: マークを `inclusive: false` にしない。ボタンで掛けてから打つと **1 文字目しか
// 入らない**（打つ度にカーソルがマークの右端に来て外れる）。マークから出るのは
// 書き手が合図した時だけにする。

import { Extension } from "@tiptap/core";
import { Mark as PmMark } from "@tiptap/pm/model";
import type { ResolvedPos } from "@tiptap/pm/model";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import type { EditorState } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";

// 箇条書き・番号付き・チェックリストの項目の中か。
//
// **リストの中では落とさない。** 箇条書きの項目を太字で並べる書き方があり、
// 項目を増やすたびに太字が外れると、1 項目ごとに掛け直す事になる。
function inListItem($pos: ResolvedPos): boolean {
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    const name = $pos.node(depth).type.name;
    if (name === "listItem" || name === "taskItem") return true;
  }
  return false;
}

// マークを落とすか。**行が増えて、その新しい行が空で、リストの中でない時だけ。**
//
// 行の途中で切った時（新しい行に文字が続く）に落とすと、後ろの文字のマークと
// 食い違うカーソルになる。ボタンで掛けただけの時は本文が変わらないので当たらない。
function shouldDropMarks(state: EditorState): boolean {
  const selection = state.selection;
  if (!(selection instanceof TextSelection) || !selection.empty) return false;
  const $from = selection.$from;
  if (!$from.parent.isTextblock || $from.parent.content.size !== 0) return false;
  if (inListItem($from)) return false;
  const stored = state.storedMarks;
  return stored !== null && stored.length > 0;
}

// 行の末尾にあるマークの右端で ArrowRight。**カーソルは動かさず、マークだけ外す。**
//
// 右端では「マークの中」と「マークの外」が同じ位置になる。ProseMirror は手前の文字の
// マークを引き継ぐので、外に出る合図が要る。1 回目の ArrowRight で外し、2 回目で本当に動く。
//
// WhyNot: 行の途中のマークの境目では取らない。**右に文字がある所で矢印を食べると、
// 1 回押しても何も動かない。** 境目の先には別の文字があるので、素直に 1 文字進めば
// もうマークの外にいる。抜けられないのは、右に何も無い行の末尾だけ。
//
// **文字を選んでいる間も同じ。** ツールバーのボタンは文字を選ばないと押せないので、
// 掛けた直後のカーソルは必ず選択の形をしている。そこで ArrowRight を素の動きに任せると
// 選択が畳まれるだけで、続けて打った文字がマークの中に入る（実機で 8 つ全部が入った）。
// 1 回の ArrowRight で「行末へ畳む」と「マークを外す」を一緒にやる。
function escapeMark(view: EditorView): boolean {
  const state = view.state;
  const selection = state.selection;
  if (!(selection instanceof TextSelection)) return false;

  const $to = selection.$to;
  if (!$to.parent.isTextblock) return false;
  // 右に文字があるなら、素直に 1 文字進めばもうマークの外。
  if ($to.nodeAfter) return false;
  if (!$to.nodeBefore) return false;

  const here = (selection.empty ? state.storedMarks : null) ?? $to.marks();
  if (here.length === 0) return false;

  const tr = state.tr;
  if (!selection.empty) tr.setSelection(TextSelection.create(tr.doc, $to.pos));
  view.dispatch(tr.setStoredMarks(PmMark.none));
  return true;
}

// マークの右端で 2 つ目の Space。**2 つ目だけマークの外に入れる。**
//
// WhyNot: 1 つ目の Space を消して打ち直さない。`a b` のようにマークの中に空白を
// 入れたい場面があり、消すと「空白を含むコード」が書けなくなる。
function escapeBySpace(view: EditorView, from: number, to: number, text: string): boolean {
  if (text !== " ") return false;
  const state = view.state;
  const $from = state.doc.resolve(from);
  const before = $from.nodeBefore;
  // 1 つ目の Space はマークの中に残す。**手前が空白の時だけ抜ける合図になる。**
  if (!before || !before.isText || !before.text?.endsWith(" ")) return false;

  const after = state.doc.resolve(to).nodeAfter;
  const outside = after ? after.marks : PmMark.none;
  const here = state.storedMarks ?? $from.marks();
  const leaving = here.filter((mark) => !mark.isInSet(outside));
  if (leaving.length === 0) return false;

  const tr = state.tr.insertText(text, from, to);
  for (const mark of leaving) tr.removeMark(from, from + text.length, mark.type);
  tr.setStoredMarks(here.filter((mark) => mark.isInSet(outside)));
  view.dispatch(tr);
  return true;
}

// コードの箱の右端で打った `` ` ``。**箱の外に入れる。**
//
// WhyNot: 箱の中に残さない。`` `x` `` は箱の外で書く記法なので、箱の右端で打った 1 つが
// 中に入ると「バッククォート 1 つでコードになった」ように見える（`a`b` の 1 つでは
// ならない事と食い違う）。
function escapeByTick(view: EditorView, from: number, to: number, text: string): boolean {
  if (text !== "`") return false;
  const state = view.state;
  const code = state.schema.marks.code;
  if (!code) return false;
  const here = state.storedMarks ?? state.doc.resolve(from).marks();
  if (!code.isInSet(here)) return false;
  // 右にまだ箱の中の文字があるなら、打った物は箱の中。
  const after = state.doc.resolve(to).nodeAfter;
  if (after && code.isInSet(after.marks)) return false;
  const tr = state.tr.insertText(text, from, to);
  tr.removeMark(from, from + text.length, code);
  tr.setStoredMarks(here.filter((mark) => mark.type !== code));
  view.dispatch(tr);
  return true;
}

/** 段落を変えた時とマークの右端で、掛かっている装飾から抜ける。 */
export const MarkEscape = Extension.create({
  name: "markEscape",

  // **TipTap の `exitable` より先に呼ばれる所に置く。**
  //
  // `@tiptap/extension-code` だけが `exitable: true` を持っていて、TipTap はその mark に
  // ArrowRight の keymap（`Mark.handleExit`）を足す。それは抜けるついでに**空白を 1 つ
  // 打ち込む**（`tr.insertText(" ")`）ので、先に取らないと `code` の後ろだけ空白が増える。
  // 優先度が高い拡張のプラグインが先に走る（`ExtensionManager.plugins` が並べ替える）。
  priority: 150,

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey("markEscape"),

        // WhyNot: Enter の押下を捕まえて自分で分けない。**リスト・引用・コードブロックが
        // それぞれ Enter に割り込んでいて、先に返った物より後ろでは押下が見えない**
        // （実際に見えず、段落のマークが落ちなかった）。結果の状態だけを見る。
        appendTransaction: (trs, _old, next) => {
          if (!trs.some((tr) => tr.docChanged)) return undefined;
          if (!shouldDropMarks(next)) return undefined;
          return next.tr.setStoredMarks(PmMark.none).setMeta("addToHistory", false);
        },

        props: {
          handleKeyDown(view, event) {
            if (event.key !== "ArrowRight") return false;
            if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return false;
            return escapeMark(view);
          },

          handleTextInput: (view, from, to, text) =>
            escapeBySpace(view, from, to, text) || escapeByTick(view, from, to, text),
        },
      }),
    ];
  },
});
