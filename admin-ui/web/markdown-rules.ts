// マークダウンで書いた時に、その場で形が変わる所の足りない分。
//
// TipTap が既に持っている物（`# ` `- ` `1. ` `> ` ``` `--- ` `[ ] ` `**太字**` など）は
// そのまま使う。ここに置くのは、**書き手が普通に打つのに変わらなかった 3 つ**。
//
//   - `- [ ] `  箇条書きの中でチェックにする
//   - `1) `     番号付き（`.` だけでなく `)` も）
//   - `[文字](URL)` リンク
//
// **`| ` から表は作らない。** 表は升目で大きさを選ぶ方が確実で、Notion / Craft /
// Google ドキュメントも記法では作らせない。`==蛍光ペン==` も入れない（CMS の
// マークは bold / italic / strike / underline / code / link / math だけ）。

import { Extension, InputRule, wrappingInputRule } from "@tiptap/core";
import type { ResolvedPos } from "@tiptap/pm/model";

// 今いる所が、箇条書き・番号付きの項目の中か。
function inPlainList($from: ResolvedPos): boolean {
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const name = $from.node(depth).type.name;
    if (name === "taskItem" || name === "taskList") return false;
    if (name === "listItem") return true;
  }
  return false;
}

export const MarkdownRules = Extension.create({
  name: "markdownRules",

  addInputRules() {
    const schema = this.editor.schema;

    return [
      // 箇条書きの中の `[ ] `。
      //
      // **空の段落で打つと変わるのに、`- ` を打ってからだと変わらない。**
      // TaskItem の規則は段落を包み直す物で、箇条書きの項目の中では包めずに黙って何もしない。
      // マークダウンとしては `- [ ] ` の方が普通なので、こちらが効かないのは手が止まる。
      //
      // **変えるのはリストごと。** taskItem は taskList の中、listItem は bulletList の中に
      // しか置けないので、1 項目だけチェックに変える形はスキーマに無い。
      new InputRule({
        find: /^\s*\[([ |xX])?\]\s$/,
        handler: ({ state, range, match, chain }) => {
          if (!inPlainList(state.selection.$from)) return;
          chain()
            .deleteRange(range)
            .toggleList("taskList", "taskItem")
            .updateAttributes("taskItem", { checked: /[xX]/.test(match[1] ?? "") })
            .run();
        },
      }),

      // `1) `。TipTap が持っているのは `1. ` だけ。
      wrappingInputRule({
        find: /^(\d+)\)\s$/,
        type: schema.nodes.orderedList,
        getAttributes: (match) => ({ start: Number(match[1]) }),
        joinPredicate: (match, node) => node.childCount + node.attrs.start === Number(match[1]),
      }),

      // `[文字](URL)`。
      //
      // WhyNot: `markInputRule` を使わない。**最後の捕まえた組を残す文字として使う**ので、
      // リンクでは URL の方が残ってしまう。
      //
      // WhyNot: 入れた後にリンクを外すのを省かない。省くと、続けて打った文字まで
      // 同じリンクの中に入る。
      new InputRule({
        find: /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)$/,
        handler: ({ range, match, chain }) => {
          chain()
            .deleteRange(range)
            .insertContent({ type: "text", text: match[1], marks: [{ type: "link", attrs: { href: match[2] } }] })
            .unsetMark("link")
            .run();
        },
      }),
    ];
  },
});
