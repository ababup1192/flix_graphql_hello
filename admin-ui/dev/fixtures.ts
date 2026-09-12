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
    name: "inline-code",
    title: "文の中のコード",
    doc: {
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            { type: "text", text: "まえ " },
            { type: "text", marks: [{ type: "code" }], text: "code" },
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
    name: "code-lines",
    title: "5 行のコード",
    doc: {
      type: "doc",
      content: [
        {
          type: "codeBlock",
          attrs: { language: null, fileName: null, highlightLines: null },
          content: [{ type: "text", text: "const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;" }],
        },
        paragraph(""),
      ],
    },
  },
  {
    name: "math",
    title: "ブロックの数式",
    doc: {
      type: "doc",
      content: [paragraph("すうしきのまえ"), { type: "mathBlock", attrs: { tex: "E = mc^2" } }, paragraph("")],
    },
  },
  {
    name: "blocks",
    title: "段落とコードと数式",
    doc: {
      type: "doc",
      content: [
        paragraph("外の段落 その 1"),
        {
          type: "codeBlock",
          attrs: { language: null, fileName: null, highlightLines: null },
          content: [{ type: "text", text: "const a = 1\nconst b = 2" }],
        },
        paragraph("外の段落 その 2"),
        { type: "mathBlock", attrs: { tex: "E = mc^2" } },
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
  {
    name: "image-between",
    title: "前後に行のある画像",
    doc: {
      type: "doc",
      content: [
        paragraph("うえの行"),
        { type: "image", content: [{ type: "imageItem", attrs: { assetId: "asset-1" } }] },
        paragraph("したの行"),
      ],
    },
  },
  {
    name: "table-between",
    title: "前に行のある表",
    doc: {
      type: "doc",
      content: [
        ...Array.from({ length: 3 }, (_ignore, index) => paragraph(`うめ ${index}`)),
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
  {
    name: "table-wide",
    title: "列の多い表",
    doc: {
      type: "doc",
      content: [
        {
          type: "table",
          content: [1, 2].map((row) => ({
            type: "tableRow",
            content: [1, 2, 3, 4, 5, 6, 7, 8].map((column) => ({
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
  {
    name: "parts",
    title: "帯と浮く面のある塊",
    doc: {
      type: "doc",
      content: [
        ...Array.from({ length: 6 }, (_ignore, index) => paragraph(`うめ ${index}`)),
        {
          type: "codeBlock",
          attrs: { language: "javascript", fileName: null, highlightLines: null },
          content: [{ type: "text", text: "const a = 1" }],
        },
        { type: "mathBlock", attrs: { tex: "E = mc^2" } },
        { type: "linkCard", attrs: { url: "https://example.com/parts" } },
        paragraph(""),
      ],
    },
  },
  {
    name: "long",
    title: "長い本文",
    doc: {
      type: "doc",
      content: [
        ...Array.from({ length: 20 }, (_ignore, index) => paragraph(`長い本文の ${index} 行目です。`)),
        {
          type: "codeBlock",
          attrs: { language: null, fileName: null, highlightLines: null },
          content: [{ type: "text", text: "const a = 1" }],
        },
        ...Array.from({ length: 20 }, (_ignore, index) => paragraph(`長い本文の ${index + 20} 行目です。`)),
        paragraph(""),
      ],
    },
  },
];

export const fixtureOf = (name: string): Fixture => FIXTURES.find((found) => found.name === name) ?? FIXTURES[0];
