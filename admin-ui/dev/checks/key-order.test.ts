// キーが「どこへ、どの順で」渡るかの表。
//
// Enter / Backspace / 矢印 / Tab / Escape は 10 以上の拡張が取り合っている。
// **先に返った物より後ろでは押下が見えない**ので、順が変わると黙って別の物が効く
// （Enter がリスト・引用・コードブロックに食われて段落のマークが落ちなかったのがこれ。
// `web/mark-escape.ts` は押下ではなく結果の状態を見る形で回避している）。
//
// 見るのは 3 つ。
//   1. 渡る順（editorProps → 優先度の順に並んだ拡張のプラグイン）
//   2. ブロックの種類 × キー で、実際に効いた物（doc の形とカーソルの居場所）
//   3. 欄（数式の TeX・コードのファイル名・出典・キャプション）から矢印で出られる
//
// WhyNot: 順をコードの並び順で確かめない。TipTap は `priority` で並べ替えるので、
// 書いた順と渡る順は別物（`markEscape` は 150 で、書いた場所より前に来る）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, typeText, settle, type Harness } from "../harness";
import { isSelectAll } from "../../web/ui";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const inner = (h: Harness) => (h.editor as any).editor;
const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;

// 描き終わるまで 2 拍待つ。
const frame = () =>
  new Promise((done) => window.requestAnimationFrame(() => window.requestAnimationFrame(done)));

// ------------------------------------------------------------------
// 1. 渡る順
// ------------------------------------------------------------------

// キーを取り合う拡張が、優先度で並んだ後の順。**この並びが割り込みの順。**
//
// 上から: 貼り付け（1100）→ 段落とリンク（1000）→ マークから抜ける（150）→
// リストの Backspace（101）→ 中核と StarterKit と自前の node（100、登録した順）。
const EXTENSION_ORDER = [
  "urlPaste",
  "paragraph",
  "link",
  "markEscape",
  "listItemBranchingDeleteKeymap",
  "taskItemBranchingDeleteKeymap",
  "editable",
  "clipboardTextSerializer",
  "commands",
  "focusEvents",
  "keymap",
  "tabindex",
  "drop",
  "paste",
  "delete",
  "textDirection",
  "starterKit",
  "bold",
  "bulletList",
  "doc",
  "dropCursor",
  "hardBreak",
  "heading",
  "undoRedo",
  "horizontalRule",
  "italic",
  "listItem",
  "listKeymap",
  "orderedList",
  "strike",
  "text",
  "code",
  "blockquote",
  "quoteCite",
  "callout",
  "details",
  "codeBlock",
  "image",
  "imageItem",
  "uploading",
  "imageDrop",
  "taskList",
  "taskItem",
  "underline",
  "sub",
  "sup",
  "highlight",
  "raisedCaret",
  "table",
  "tableRow",
  "tableHeader",
  "tableCell",
  "codeEditing",
  "blockEdges",
  "markdownRules",
  "math",
  "mathBlock",
  "linkCard",
  "embed",
  "bubbleMenu",
  "passthrough",
];

test("拡張の割り込みの順（優先度で並べ直した後）", async () => {
  const h = (harness = await mount("empty"));
  expect(inner(h).extensionManager.extensions.map((one: any) => one.name)).toEqual(EXTENSION_ORDER);
});

// 名前の付いた鍵のプラグイン。**優先度の高い物が先**で、`markEscape` は
// `code` の `exitable`（TipTap が足す ArrowRight の keymap）より前に居る必要がある。
test("鍵を見るプラグインの並び", async () => {
  const h = (harness = await mount("empty"));
  const named = inner(h)
    .state.plugins.filter((one: any) => one.props?.handleKeyDown || one.props?.handleTextInput)
    .map((one: any) => String(one.key).replace(/\$\d*$/, ""))
    .filter((name: string) => !name.startsWith("plugin"));
  expect(named).toEqual(["markEscape", "blockEdges", "codeBrackets", "selectingCells", "quoteCiteNotEmpty"]);
});

// **editorProps が一番先。** ブロックの一覧（`/` と「+」）はここで上下と Enter を取る
// （`tiptap-editor.ts` の `handleKeyDown`）ので、一覧が開いている間はどの拡張にも渡らない。
test("editorProps が拡張のプラグインより先に見る", async () => {
  const h = (harness = await mount("empty"));
  await typeText("ab");
  const view = inner(h).view;
  const seen: string[] = [];
  const restore: Array<() => void> = [];

  const watch = (host: any, label: string) => {
    const before = host.handleKeyDown;
    if (!before) return;
    host.handleKeyDown = (...args: any[]) => {
      seen.push(label);
      return before(...args);
    };
    restore.push(() => {
      host.handleKeyDown = before;
    });
  };

  watch(view.props, "editorProps");
  for (const plugin of view.state.plugins) {
    const name = String(plugin.key).replace(/\$\d*$/, "");
    if (name === "markEscape" || name === "blockEdges") watch(plugin.props, name);
  }

  // 何も取らないキー（マークの無い所の ArrowRight）。取られると後ろまで届かない。
  await userEvent.keyboard("{ArrowRight}");
  for (const undo of restore) undo();
  expect(seen).toEqual(["editorProps", "markEscape", "blockEdges"]);
});

// ------------------------------------------------------------------
// 2. ブロックの種類 × キー
// ------------------------------------------------------------------

type Spot = { name: string; fixture: string; go: (h: Harness) => Promise<void> | void };

function caretIn(h: Harness, name: string, offset: number) {
  const view = inner(h);
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + offset);
}

const SPOTS: Spot[] = [
  { name: "段落", fixture: "empty", go: () => typeText("あい") },
  { name: "見出し", fixture: "empty", go: () => typeText("# あい") },
  { name: "箇条書き", fixture: "empty", go: () => typeText("- あい") },
  { name: "チェック", fixture: "empty", go: () => typeText("[ ] あい") },
  { name: "引用の段落", fixture: "quote", go: (h) => caretIn(h, "blockquote", 3) },
  { name: "出典", fixture: "quote", go: (h) => caretIn(h, "quoteCite", 1) },
  { name: "コード", fixture: "code-lines", go: (h) => caretIn(h, "codeBlock", 5) },
  { name: "キャプション", fixture: "image", go: (h) => h.caretInCaption() },
  { name: "セル", fixture: "table", go: (h) => caretIn(h, "tableCell", 3) },
];

// doc の形とカーソルの居場所を 1 行で読む。
// `doc の直下の node` `#node の総数` `いる textblock@文字目` `表なら今のセル`。
function where(h: Harness): string {
  const view = inner(h);
  const { $from } = view.state.selection;
  const top: string[] = [];
  view.state.doc.forEach((node: any) => top.push(node.type.name));
  const count = h.names().filter((one) => one !== "text").length;
  let cell = "";
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") cell = ` cell=${node.textContent}`;
  }
  return `${top.join(",")} #${count} ${$from.parent.type.name}@${$from.parentOffset}${cell}`;
}

// [ブロック, キー, 押す前, 押した後]。
//
// 読み方の例:
//   - 「出典 {Enter} が前と同じ」= `quote-node.ts` が食べている（引用が割れない）
//   - 「コード {Enter} が codeBlock@5」= `code-editing.ts` が改行を入れている（段落が増えない）
//   - 「箇条書き {Enter} で #3 → #5」= listItem が項目を増やしている
//   - 「段落 {ArrowDown} で paragraph が 1 つ増える」= `block-edges.ts` の疑似行
//
// WhyNot: 「上に何も無い行の ↑」を表に入れない。**行頭へ動かすのはブラウザの既定**で、
// 割り込みの順とは関係が無い。その上、描き終わる前に押すと動かない事があり、
// 検査が 6 回に 1 回落ちた。上に物がある形（出典・キャプション・セル）だけを見る。
const MATRIX: Array<[string, string, string, string]> = [
  ["段落", "{Enter}", "paragraph #1 paragraph@2", "paragraph,paragraph #2 paragraph@0"],
  ["段落", "{Backspace}", "paragraph #1 paragraph@2", "paragraph #1 paragraph@1"],
  ["段落", "{ArrowDown}", "paragraph #1 paragraph@2", "paragraph,paragraph #2 paragraph@0"],
  ["段落", "{Tab}", "paragraph #1 paragraph@2", "paragraph #1 paragraph@2"],
  ["段落", "{Escape}", "paragraph #1 paragraph@2", "paragraph #1 paragraph@2"],

  ["見出し", "{Enter}", "heading #1 heading@2", "heading,paragraph #2 paragraph@0"],
  ["見出し", "{Backspace}", "heading #1 heading@2", "heading #1 heading@1"],
  ["見出し", "{ArrowDown}", "heading #1 heading@2", "heading,paragraph #2 paragraph@0"],
  ["見出し", "{Tab}", "heading #1 heading@2", "heading #1 heading@2"],
  ["見出し", "{Escape}", "heading #1 heading@2", "heading #1 heading@2"],

  ["箇条書き", "{Enter}", "bulletList #3 paragraph@2", "bulletList #5 paragraph@0"],
  ["箇条書き", "{Backspace}", "bulletList #3 paragraph@2", "bulletList #3 paragraph@1"],
  ["箇条書き", "{ArrowDown}", "bulletList #3 paragraph@2", "bulletList,paragraph #4 paragraph@0"],
  ["箇条書き", "{Tab}", "bulletList #3 paragraph@2", "bulletList #3 paragraph@2"],
  ["箇条書き", "{Escape}", "bulletList #3 paragraph@2", "bulletList #3 paragraph@2"],

  ["チェック", "{Enter}", "taskList #3 paragraph@2", "taskList #5 paragraph@0"],
  ["チェック", "{Backspace}", "taskList #3 paragraph@2", "taskList #3 paragraph@1"],
  // WhyNot: 箇条書きと揃えない。チェックの項目の中の ↑ は、上に何も無い所では
  // 行頭へも動かない（箇条書きは動く）。今の姿を表に載せ、直すかは別に決める。
  ["チェック", "{ArrowUp}", "taskList #3 paragraph@2", "taskList #3 paragraph@2"],
  ["チェック", "{ArrowDown}", "taskList #3 paragraph@2", "taskList,paragraph #4 paragraph@0"],
  ["チェック", "{Tab}", "taskList #3 paragraph@2", "taskList #3 paragraph@2"],
  ["チェック", "{Escape}", "taskList #3 paragraph@2", "taskList #3 paragraph@2"],

  ["引用の段落", "{Enter}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #5 paragraph@0"],
  ["引用の段落", "{Backspace}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #4 paragraph@0"],
  ["引用の段落", "{ArrowUp}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #4 paragraph@1"],
  ["引用の段落", "{ArrowDown}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #4 quoteCite@0"],
  ["引用の段落", "{Tab}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #4 paragraph@1"],
  ["引用の段落", "{Escape}", "blockquote,paragraph #4 paragraph@1", "blockquote,paragraph #4 paragraph@1"],

  // 出典は Enter と Backspace を食べる（引用が割れない・出典が消えない）。
  ["出典", "{Enter}", "blockquote,paragraph #4 quoteCite@0", "blockquote,paragraph #4 quoteCite@0"],
  ["出典", "{Backspace}", "blockquote,paragraph #4 quoteCite@0", "blockquote,paragraph #4 quoteCite@0"],
  ["出典", "{ArrowUp}", "blockquote,paragraph #4 quoteCite@0", "paragraph,blockquote,paragraph #5 paragraph@0"],
  ["出典", "{ArrowDown}", "blockquote,paragraph #4 quoteCite@0", "blockquote,paragraph #4 paragraph@0"],
  ["出典", "{Tab}", "blockquote,paragraph #4 quoteCite@0", "blockquote,paragraph #4 quoteCite@0"],
  ["出典", "{Escape}", "blockquote,paragraph #4 quoteCite@0", "blockquote,paragraph #4 quoteCite@0"],

  // コードは Enter が改行、Tab が字下げ（`code-editing.ts`）。段落は増えない。
  ["コード", "{Enter}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@5"],
  ["コード", "{Backspace}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@3"],
  ["コード", "{ArrowUp}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@4"],
  ["コード", "{ArrowDown}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@17"],
  ["コード", "{Tab}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@6"],
  ["コード", "{Escape}", "codeBlock,paragraph #2 codeBlock@4", "codeBlock,paragraph #2 codeBlock@4"],

  // キャプションは Enter と Backspace を食べる（画像が消えない）。
  ["キャプション", "{Enter}", "image,paragraph #3 imageItem@0", "image,paragraph #3 imageItem@0"],
  ["キャプション", "{Backspace}", "image,paragraph #3 imageItem@0", "image,paragraph #3 imageItem@0"],
  ["キャプション", "{ArrowUp}", "image,paragraph #3 imageItem@0", "paragraph,image,paragraph #4 paragraph@0"],
  ["キャプション", "{ArrowDown}", "image,paragraph #3 imageItem@0", "image,paragraph #3 paragraph@0"],
  ["キャプション", "{Tab}", "image,paragraph #3 imageItem@0", "image,paragraph #3 imageItem@0"],
  ["キャプション", "{Escape}", "image,paragraph #3 imageItem@0", "image,paragraph #3 imageItem@0"],

  // セルの中の Enter はセルの中で段落が増える（表は割れない）。Tab は隣のセルへ。
  ["セル", "{Enter}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #17 paragraph@0 cell=2-1"],
  ["セル", "{Backspace}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #16 paragraph@0 cell=-1"],
  ["セル", "{ArrowUp}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #16 paragraph@0 cell=1-1"],
  ["セル", "{ArrowDown}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #16 paragraph@0"],
  ["セル", "{Tab}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #16 paragraph@0 cell=2-2"],
  ["セル", "{Escape}", "table,paragraph #16 paragraph@1 cell=2-1", "table,paragraph #16 paragraph@1 cell=2-1"],
];

for (const [block, key, before, after] of MATRIX) {
  test(`${block}の ${key} → ${after}`, async () => {
    const spot = SPOTS.find((one) => one.name === block)!;
    const h = (harness = await mount(spot.fixture));
    await spot.go(h);
    // **描き終わるのを待ってから押す。** 矢印は行の高さと折り返しを見て動くので、
    // 組み上がる途中で押すと別の行へ行く（実際に 6 回に 1 回ずれた）。
    await settle();
    await frame();
    // **本文に焦点が戻っているのを確かめてから押す。** 焦点が外に居る間の矢印は
    // どこにも届かず、押した事にならない（実際に 5 回に 1 回届かなかった）。
    await vi.waitFor(() => expect(inner(h).view.hasFocus()).toBe(true));
    const start = where(h);
    await userEvent.keyboard(key);
    await settle();
    await vi.waitFor(() => expect({ before: start, after: where(h) }).toEqual({ before, after }));
  });
}

// 端の Backspace / Delete を素の動きに任せると、隣の段落と結合して
// 画像と出典が消える（`image-node.ts` / `quote-node.ts` の `atEdge`）。
// **前に行のある形で見る。** 先頭に置くと結合する相手が無く、素通りする。
test("キャプションの先頭で Backspace しても画像が消えない", async () => {
  const h = (harness = await mount("image-between"));
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("{Backspace}");
  await settle();
  expect({ image: h.names().includes("imageItem"), text: h.text() }).toEqual({ image: true, text: "うえの行したの行" });
});

test("キャプションの末尾で Delete しても画像が消えない", async () => {
  const h = (harness = await mount("image-between"));
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("{Delete}");
  await settle();
  expect({ image: h.names().includes("imageItem"), text: h.text() }).toEqual({ image: true, text: "うえの行したの行" });
});

test("出典の先頭で Backspace しても出典が消えない", async () => {
  const h = (harness = await mount("quote"));
  caretIn(h, "quoteCite", 1);
  await settle();
  await userEvent.keyboard("{Backspace}");
  await settle();
  expect({ cite: h.names().includes("quoteCite"), text: h.text() }).toEqual({
    cite: true,
    text: "引用された文章がここに入ります。出典の名前",
  });
});

test("出典の末尾で Delete しても出典が消えない", async () => {
  const h = (harness = await mount("quote"));
  caretIn(h, "quoteCite", 7);
  await settle();
  await userEvent.keyboard("{Delete}");
  await settle();
  expect({ cite: h.names().includes("quoteCite"), text: h.text() }).toEqual({
    cite: true,
    text: "引用された文章がここに入ります。出典の名前",
  });
});

// ------------------------------------------------------------------
// 3. Enter でマークが落ちる / 残る
// ------------------------------------------------------------------

// **Enter はリスト・引用・コードブロックに食われる**ので、`mark-escape.ts` は押下ではなく
// 結果の状態を見る。落とすのは「行が増えて、その行が空で、リストの外」の時だけ。
const AFTER_ENTER: Array<[string, string, string[]]> = [
  ["段落", "", []],
  ["見出し", "# ", []],
  ["引用", "> ", []],
  // リストは残す（項目ごとに掛け直さずに済む）。
  ["箇条書き", "- ", ["bold"]],
  ["チェック", "[ ] ", ["bold"]],
];

for (const [name, prefix, marks] of AFTER_ENTER) {
  test(`${name}で Enter を押した後に残るマーク: ${marks.join("+") || "なし"}`, async () => {
    const h = (harness = await mount("empty"));
    await typeText(prefix);
    h.apply("bold");
    await typeText("ふとい");
    await userEvent.keyboard("{Enter}");
    await settle();
    expect(h.marks()).toEqual(marks);
  });
}

// ------------------------------------------------------------------
// 4. 欄から矢印で出る
// ------------------------------------------------------------------

// 帯と node view の中の欄は、鍵を全部食べると前後の行へ移れなくなる（`ui.ts` の `field`）。
const FIELDS: Array<[string, string, (h: Harness) => Promise<void>]> = [
  [
    "数式の TeX",
    ".tt-mathblock-src",
    async (h) => {
      await userEvent.click(at(h, ".tt-mathblock-out"));
      await vi.waitFor(() => expect(document.activeElement).toBe(at(h, ".tt-mathblock-src")));
    },
  ],
  [
    "コードのファイル名",
    ".tt-code-file",
    async (h) => {
      await userEvent.click(at(h, ".tt-code-file"));
      await vi.waitFor(() => expect(document.activeElement).toBe(at(h, ".tt-code-file")));
    },
  ],
];

for (const [name, selector, go] of FIELDS) {
  for (const key of ["ArrowUp", "ArrowDown"] as const) {
    test(`${name}の欄から ${key} で本文へ出る`, async () => {
      const h = (harness = await mount("blocks"));
      await go(h);
      await userEvent.keyboard(`{${key}}`);
      await settle();
      expect({
        left: document.activeElement !== at(h, selector),
        inBody: inner(h).view.hasFocus(),
      }).toEqual({ left: true, inBody: true });
    });
  }
}

// ------------------------------------------------------------------
// 5. 全選択の修飾キー（Mac の判定）
// ------------------------------------------------------------------

// **macOS は Command だけ。** Control+A は OS 全体で「行頭へ移動」なので奪わない
// （`userAgentData.platform` が小文字始まりの "macOS" を返して判定が外れ、
// 実際に Mac で Control+A が全選択になった）。
type Platform = { platform: string; agentData?: string };

function asPlatform(one: Platform, run: () => void) {
  const kept = {
    platform: Object.getOwnPropertyDescriptor(navigator, "platform"),
    agentData: Object.getOwnPropertyDescriptor(navigator, "userAgentData"),
  };
  Object.defineProperty(navigator, "platform", { configurable: true, get: () => one.platform });
  Object.defineProperty(navigator, "userAgentData", { configurable: true, get: () => (one.agentData === undefined ? undefined : { platform: one.agentData }) });
  try {
    run();
  } finally {
    if (kept.platform) Object.defineProperty(navigator, "platform", kept.platform);
    else delete (navigator as any).platform;
    if (kept.agentData) Object.defineProperty(navigator, "userAgentData", kept.agentData);
    else delete (navigator as any).userAgentData;
  }
}

// [名前, 見せる platform, keydown, 全選択か]
const SELECT_ALL: Array<[string, Platform, KeyboardEventInit, boolean]> = [
  ["Mac の ⌘A", { platform: "MacIntel" }, { key: "a", metaKey: true }, true],
  ["Mac の Control+A", { platform: "MacIntel" }, { key: "a", ctrlKey: true }, false],
  // `userAgentData.platform` は空を返す事があり、返す時は "macOS"（先頭が小文字）。
  ["macOS（userAgentData）の ⌘A", { platform: "", agentData: "macOS" }, { key: "a", metaKey: true }, true],
  ["macOS（userAgentData）の Control+A", { platform: "", agentData: "macOS" }, { key: "a", ctrlKey: true }, false],
  ["userAgentData が空なら platform を見る", { platform: "MacIntel", agentData: "" }, { key: "a", metaKey: true }, true],
  ["iPad の ⌘A", { platform: "iPad" }, { key: "a", metaKey: true }, true],
  ["Windows の Control+A", { platform: "Win32" }, { key: "a", ctrlKey: true }, true],
  ["Windows の ⌘A", { platform: "Win32" }, { key: "a", metaKey: true }, false],
  ["Linux の Control+A", { platform: "Linux x86_64" }, { key: "a", ctrlKey: true }, true],
  ["大文字の A も同じ", { platform: "Win32" }, { key: "A", ctrlKey: true }, true],
  ["Option を足したら別の操作", { platform: "MacIntel" }, { key: "a", metaKey: true, altKey: true }, false],
  ["修飾キー無しは全選択ではない", { platform: "Win32" }, { key: "a" }, false],
  ["別のキーは全選択ではない", { platform: "Win32" }, { key: "s", ctrlKey: true }, false],
];

for (const [name, platform, init, expected] of SELECT_ALL) {
  test(`全選択の判定: ${name} → ${expected}`, () => {
    asPlatform(platform, () => {
      expect(isSelectAll(new KeyboardEvent("keydown", init))).toBe(expected);
    });
  });
}
