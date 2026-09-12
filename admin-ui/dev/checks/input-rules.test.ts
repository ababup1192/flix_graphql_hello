// 入力規則の一覧（記法 → 何になるか）を 1 か所の表で持ち、機械で見る。
//
// 出所は 3 つ。**ここに無い規則は「無い」と読める**ようにする:
//   - `web/tiptap-editor.ts`: StarterKit（見出し・箇条書き・番号付き・区切り線・太字・斜体・
//     打ち消し）、CodeBlockLowlight（``` ）、Code（`x`）、Link（[文字](URL)）、
//     TaskItem（[ ] ）、QuoteNode（> ）、MathMark（$x$）、MathBlock（$$ ）
//   - `web/markdown-rules.ts`: `- [ ] ` / `1) ` / `[文字](URL)`
//   - `web/text-marks.ts`: `~x~` / `^x^` / `==x==`
//
// 見るのは 2 つ。
//   1. 表のすべての行が**実際に打鍵して**期待どおりになる
//   2. **記号が重なる組**（`*` と `**`、`~` と `~~`、`` ` `` と ``` ```、`_` と `__`、
//      `=` と `==`、`$` と `$$`、`-` と `--- `、`#` の数）で片方が片方を食わない
//
// WhyNot: 規則の正規表現を読んで確かめない。規則は他の規則と node view と handleTextInput の
// 後ろで動くので、単体では当たっても打鍵では当たらない（`- ` の後の `[ ] ` が実際にそうだった）。
import { expect, test, afterEach } from "vitest";
import { mount, typeText, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// doc を「node の名前と、文字に乗ったマーク」の 1 行で読む。
// 見出しの level・コードブロックの language・チェックの on/off まで出す。
function shapeOf(h: Harness): string {
  const view = (h.editor as any).editor;
  const parts: string[] = [];
  view.state.doc.descendants((node: any) => {
    if (node.isText) {
      parts.push(`「${node.text}」[${node.marks.map((mark: any) => mark.type.name).join("+") || "なし"}]`);
      return;
    }
    const level = node.attrs?.level ? `(${node.attrs.level})` : "";
    const language = node.attrs?.language ? `{${node.attrs.language}}` : "";
    const checked = node.attrs && "checked" in node.attrs ? `<${node.attrs.checked}>` : "";
    parts.push(`${node.type.name}${level}${language}${checked}`);
  });
  return parts.join(" ");
}

// [打つ文字, doc の形]。**空の本文の頭から打つ。**
const RULES: Array<[string, string]> = [
  // ---- ブロックにする物 ----
  ["# ", "heading(1)"],
  ["## ", "heading(2)"],
  ["### ", "heading(3)"],
  ["#### ", "heading(4)"],
  ["- ", "bulletList listItem paragraph"],
  ["* ", "bulletList listItem paragraph"],
  ["+ ", "bulletList listItem paragraph"],
  ["1. ", "orderedList listItem paragraph"],
  ["1) ", "orderedList listItem paragraph"],
  ["> ", "blockquote paragraph"],
  ["``` ", "codeBlock"],
  ["```js ", "codeBlock{js}"],
  ["___ ", "horizontalRule paragraph"],
  ["*** ", "horizontalRule paragraph"],
  // WhyNot: `--- ` だけ後ろの段落に空白が 1 つ残るのを直さない（検査の外の話）。
  // 打った通りを表に載せ、直すかは別に決める。
  ["--- ", "horizontalRule paragraph 「 」[なし]"],
  ["$$ ", "mathBlock paragraph"],
  ["[ ] ", "taskList taskItem<false> paragraph"],
  ["[x] ", "taskList taskItem<true> paragraph"],
  // 箇条書きの中の `[ ] `（`markdown-rules.ts`。TipTap の規則だけでは効かない）。
  ["- [ ] ", "taskList taskItem<false> paragraph"],
  ["- [x] ", "taskList taskItem<true> paragraph"],

  // ---- 文字に印を付ける物 ----
  ["**太字**", "paragraph 「太字」[bold]"],
  ["__太字__", "paragraph 「太字」[bold]"],
  ["*斜体*", "paragraph 「斜体」[italic]"],
  ["_斜体_", "paragraph 「斜体」[italic]"],
  ["~~取り消し~~", "paragraph 「取り消し」[strike]"],
  ["`x`", "paragraph 「x」[code]"],
  ["H~2~O", "paragraph 「H」[なし] 「2」[sub] 「O」[なし]"],
  ["x^2^", "paragraph 「x」[なし] 「2」[sup]"],
  ["==大事==", "paragraph 「大事」[highlight]"],
  ["$x$", "paragraph 「x」[math]"],
  ["[ここ](https://example.com)", "paragraph 「ここ」[link]"],
  ["[ここ](mailto:a@example.com)", "paragraph 「ここ」[link]"],

  // ---- 何も起きない物（打った通りに残る）----
  // CMS が受ける href は http(s) と mailto だけ（`markdown-rules.ts`）。
  ["[ここ](/blog/hello)", "paragraph 「[ここ](/blog/hello)」[なし]"],
  ["##### ", "paragraph 「##### 」[なし]"],
  ["-- ", "paragraph 「-- 」[なし]"],
  ["~1つ", "paragraph 「~1つ」[なし]"],
  ["^1つ", "paragraph 「^1つ」[なし]"],
  ["=1つ", "paragraph 「=1つ」[なし]"],
  ["$1つ", "paragraph 「$1つ」[なし]"],
];

for (const [typed, shape] of RULES) {
  test(`「${typed}」→ ${shape}`, async () => {
    const h = (harness = await mount("empty"));
    await typeText(typed);
    expect(shapeOf(h)).toBe(shape);
  });
}

// 記号が重なる組。**短い方と長い方が、どちらも生き残る。**
//
// 片方が片方を食う形は、閉じを打ち終わる前に短い方が当たって起きる
// （`~~取り消し~~` の 1 つ目の `~` の直後から `~取り消し~` が読める）。
const PAIRS: Array<[string, string, string, string, string]> = [
  ["*", "*斜体*", "paragraph 「斜体」[italic]", "**太字**", "paragraph 「太字」[bold]"],
  ["_", "_斜体_", "paragraph 「斜体」[italic]", "__太字__", "paragraph 「太字」[bold]"],
  ["~", "H~2~O", "paragraph 「H」[なし] 「2」[sub] 「O」[なし]", "~~取り消し~~", "paragraph 「取り消し」[strike]"],
  ["=", "=1つ", "paragraph 「=1つ」[なし]", "==大事==", "paragraph 「大事」[highlight]"],
  ["`", "`x`", "paragraph 「x」[code]", "``` ", "codeBlock"],
  ["$", "$x$", "paragraph 「x」[math]", "$$ ", "mathBlock paragraph"],
  ["-", "- ", "bulletList listItem paragraph", "*** ", "horizontalRule paragraph"],
  ["#", "# ", "heading(1)", "#### ", "heading(4)"],
];

for (const [sign, shortTyped, shortShape, longTyped, longShape] of PAIRS) {
  test(`「${sign}」の重なり: 短い「${shortTyped}」と長い「${longTyped}」が食い合わない`, async () => {
    const h = (harness = await mount("empty"));
    await typeText(shortTyped);
    const short = shapeOf(h);
    harness.destroy();
    const other = (harness = await mount("empty"));
    await typeText(longTyped);
    expect({ short, long: shapeOf(other) }).toEqual({ short: shortShape, long: longShape });
  });
}

// 実際に起きた不具合。**表の行と別に、名前を付けて残す。**
test("`a`b` の前の 1 文字が消えない", async () => {
  const h = (harness = await mount("empty"));
  await typeText("a`b`");
  expect(shapeOf(h)).toBe("paragraph 「a」[なし] 「b」[code]");
});

test("~~ が下付きにならない", async () => {
  const h = (harness = await mount("empty"));
  await typeText("~~取り消し~~");
  expect(h.lastMarks()).toEqual(["strike"]);
});

test("バッククォート 1 つでは変わらない", async () => {
  const h = (harness = await mount("empty"));
  await typeText("a`b");
  expect(shapeOf(h)).toBe("paragraph 「a`b」[なし]");
});

// TipTap の太字・斜体・打ち消しは**前が行頭か空白の時だけ**当たる。
// 行の途中の `~~` が何も起こさないのはその決まりの通りで、こちらでは変えない。
test("前~~消~~後 は行の途中なので打った通りに残る", async () => {
  const h = (harness = await mount("empty"));
  await typeText("前~~消~~後");
  expect(shapeOf(h)).toBe("paragraph 「前~~消~~後」[なし]");
});

test("~~a~~b~c~ は打ち消しと下付きが両方付く", async () => {
  const h = (harness = await mount("empty"));
  await typeText("~~a~~b~c~");
  expect(shapeOf(h)).toBe("paragraph 「a」[strike] 「b」[なし] 「c」[sub]");
});

// 上付きと下付きは**片方の中にもう片方が無い**（`text-marks.ts` の excludes）。
test("上付きと下付きは重ならない", async () => {
  const h = (harness = await mount("empty"));
  await typeText("a");
  h.selectBack(1);
  h.apply("sup");
  h.apply("sub");
  expect(h.lastMarks()).toEqual(["sub"]);
});

// 画像のキャプションと引用の出典では入力規則を切っている
// （`tiptap-editor.ts` の handleTextInput と `quote-node.ts` の handleTextInput）。
// [名前, 初期状態, カーソルを置く]
const NO_RULES: Array<[string, string, (h: Harness) => void]> = [
  ["画像のキャプション", "image", (h) => h.caretInCaption()],
  [
    "引用の出典",
    "quote",
    (h) => {
      const view = (h.editor as any).editor;
      let at = -1;
      view.state.doc.descendants((node: any, pos: number) => {
        if (node.type.name === "quoteCite" && at < 0) at = pos + 1;
      });
      view.commands.focus();
      view.commands.setTextSelection(at);
    },
  ],
];

for (const [name, fixture, go] of NO_RULES) {
  test(`${name}では入力規則が効かない`, async () => {
    const h = (harness = await mount(fixture));
    go(h);
    // ブロックにする物（見出し）も、印を付ける物（太字）も打った通りに残る。
    await typeText("# ");
    await typeText("**太字**");
    expect({
      heading: h.names().includes("heading"),
      bold: h.lastMarks().includes("bold"),
      text: h.text().includes("# **太字**"),
    }).toEqual({ heading: false, bold: false, text: true });
  });
}

