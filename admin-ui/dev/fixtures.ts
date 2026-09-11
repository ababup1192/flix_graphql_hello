// 開発用の画面と検査が共有する「名前を付けた初期状態」。
//
// WhyNot: 検査の中に doc を直に書かない。同じ形を画面と検査で二重に持つと、
// 片方だけ直した時に「画面では再現するのに検査は通る」が起きる。
export type Fixture = { name: string; title: string; doc: unknown };

const paragraph = (text: string) => ({ type: "paragraph", content: text ? [{ type: "text", text }] : [] });

export const FIXTURES: Fixture[] = [
  {
    name: "empty",
    title: "空",
    doc: { type: "doc", content: [paragraph("")] },
  },
  {
    name: "text",
    title: "文章だけ",
    doc: {
      type: "doc",
      content: [
        { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "見出し" }] },
        paragraph("ふつうの段落です。"),
        {
          type: "paragraph",
          content: [
            { type: "text", text: "太字と" },
            { type: "text", marks: [{ type: "bold" }], text: "強い所" },
            { type: "text", text: "、それから" },
            { type: "text", marks: [{ type: "code" }], text: "code" },
            { type: "text", text: " の箱。" },
          ],
        },
      ],
    },
  },
  {
    name: "image",
    title: "画像 1 枚",
    doc: {
      type: "doc",
      content: [
        { type: "image", content: [{ type: "imageItem", attrs: { assetId: "asset-1" } }] },
        paragraph(""),
      ],
    },
  },
  {
    name: "gallery",
    title: "並べた画像",
    doc: {
      type: "doc",
      content: [
        {
          type: "image",
          content: [
            { type: "imageItem", attrs: { assetId: "asset-1" }, content: [{ type: "text", text: "1 枚目" }] },
            { type: "imageItem", attrs: { assetId: "asset-2" } },
            { type: "imageItem", attrs: { assetId: "asset-3" } },
          ],
        },
        paragraph(""),
      ],
    },
  },
  {
    name: "quote",
    title: "引用と出典",
    doc: {
      type: "doc",
      content: [
        {
          type: "blockquote",
          content: [
            paragraph("引用された文章がここに入ります。"),
            { type: "quoteCite", content: [{ type: "text", text: "出典の名前" }] },
          ],
        },
        paragraph(""),
      ],
    },
  },
  {
    name: "code",
    title: "コード",
    doc: {
      type: "doc",
      content: [
        {
          type: "codeBlock",
          attrs: { language: "typescript", fileName: "hello.ts" },
          content: [{ type: "text", text: 'const greet = (name: string) => `hello ${name}`;\ngreet("world");' }],
        },
        paragraph(""),
      ],
    },
  },
  {
    name: "table",
    title: "表",
    doc: {
      type: "doc",
      content: [
        {
          type: "table",
          content: [1, 2].map((row) => ({
            type: "tableRow",
            content: [1, 2, 3].map((column) => ({
              type: row === 1 ? "tableHeader" : "tableCell",
              attrs: { colspan: 1, rowspan: 1, colwidth: null },
              content: [paragraph(`${row}-${column}`)],
            })),
          })),
        },
        paragraph(""),
      ],
    },
  },
];

export const fixtureOf = (name: string): Fixture => FIXTURES.find((found) => found.name === name) ?? FIXTURES[0];
