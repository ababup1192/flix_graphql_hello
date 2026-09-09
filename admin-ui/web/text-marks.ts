// 上付き・下付き・蛍光ペン。
//
// **どれも中身であって飾りではない。** H₂O・m²・™ は書いた人が意味を決めた物で、
// 蛍光ペンは「ここが大事」という役割。だから HTML の要素（sub / sup / mark）で出す。
//
// WhyNot: 文字色と文字サイズは入れない。ヘッドレス CMS の役割は中身で、見た目はサイトが決める。
// 本文に色や大きさを埋めると、サイトのデザインより本文が強くなり、リニューアルと
// 暗いテーマで壊れる。Contentful / Sanity / Strapi も持っていない。
//
// WhyNot: @tiptap/extension-subscript などを入れない。**この 3 つは中身が数行**で、
// 依存を 3 つ増やすほどの物ではない。

import { InputRule, Mark, mergeAttributes } from "@tiptap/core";

type Spec = { name: string; tag: string; sign: string };

const SPECS: Spec[] = [
  { name: "sub", tag: "sub", sign: "~" },
  { name: "sup", tag: "sup", sign: "^" },
  { name: "highlight", tag: "mark", sign: "==" },
];

//
// `~x~` `^x^` `==x==`。CMS の Markdown 方言と同じ書き方。
//
// WhyNot: TipTap の `markInputRule` を使わない。**前の 1 文字を巻き込んで消す**ので、
// `H~2~O` の `H` が落ちる（実際に落ちた）。下付き・上付きは語にくっ付けて書く物なので、
// 前を空白に限る形も取れない。記号だけを消して、中の文字に印を付ける。
//
function ruleOf(sign: string) {
  const escaped = sign.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const inner = sign.length === 1 ? escaped : escaped[1];
  return new RegExp(`${escaped}([^${inner}\\s][^${inner}]*)${escaped}$`);
}

function markOf(spec: Spec) {
  return Mark.create({
    name: spec.name,

    parseHTML() {
      return [{ tag: spec.tag }];
    },

    renderHTML({ HTMLAttributes }) {
      return [spec.tag, mergeAttributes(HTMLAttributes), 0];
    },

    addInputRules() {
      const name = spec.name;
      return [
        new InputRule({
          find: ruleOf(spec.sign),
          handler: ({ range, match, chain }) => {
            chain()
              .deleteRange(range)
              .insertContent({ type: "text", text: match[1], marks: [{ type: name }] })
              .unsetMark(name)
              .run();
          },
        }),
      ];
    },
  });
}

export const Subscript = markOf(SPECS[0]);
export const Superscript = markOf(SPECS[1]);
export const Highlight = markOf(SPECS[2]);
