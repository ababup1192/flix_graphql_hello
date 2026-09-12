// 構造に依存しない物差し。
//
// 今の検査の大半は class 名と DOM の入れ子に張り付いていて、作りを変えると検査も一緒に
// 書き換わる。**作りが変わっても意味が変わらない**物だけをここに置く。
//
//   1. 高さが transaction 無しで変わっても、浮く面は基準の所に付いてくる
//      （`docs/design/editor-dom-parts.md` が「『+』が gallery でずれる」の真因を
//      「高さが transaction 無しで変わる時すべて」と特定している。画像の読み込みと折り返し）
//   2. undo / redo の後、decoration と浮く面が消えていない
//   3. 外から `doc` 属性で新しい内容が来た後も同じ
//   4. **見つけた帯すべて**で、余白を押して打っても doc が変わらない
//
// WhyNot: 帯を名前で数え上げない。増えた帯が検査から漏れるので、`ui.ts` の `bar()` が
// 必ず付ける class（`BAR_CLASS`）で**その場に出ている物を拾う**。
import { expect, test, afterEach, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { mount, press, settle, typeText, type Harness } from "../harness";
import { BAR_CLASS } from "../../web/ui";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  window.scrollTo(0, 0);
  await page.viewport(1440, 900);
});

const inner = (h: Harness) => (h.editor as any).editor;
const box = (el: Element) => el.getBoundingClientRect();

// 読み込みに時間の掛かる画像の代わり。**高さを持つ**（transaction 無しで本文が伸びる）。
const TALL_IMAGE =
  "data:image/svg+xml;charset=utf-8," +
  encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300"><rect width="400" height="300" fill="#ccc"/></svg>');

// 「+」の真ん中と、カーソルのある行の真ん中のずれ。
//
// **DOM の入れ子ではなく座標で見る。** 「+」がどの親に入っているか、行がどの要素かは
// 作りの話で、書き手に見えているのは「+」が今いる行の横に居るかどうかだけ。
function plusOffset(h: Harness): number | null {
  const plus = h.editor.querySelector<HTMLElement>(".tt-plus");
  if (!plus || plus.hidden) return null;
  const view = inner(h).view;
  const line = view.coordsAtPos(inner(h).state.selection.from);
  return Math.abs((box(plus).top + box(plus).bottom) / 2 - (line.top + line.bottom) / 2);
}

// 「+」が出るまで待つ（空の段落に焦点がある時だけ出る）。
async function waitForPlus(h: Harness) {
  inner(h).commands.focus("end");
  await settle();
  await vi.waitFor(() => expect(plusOffset(h)).not.toBeNull());
}

// 本文の高さ。
const bodyHeight = (h: Harness) => box(h.editor.querySelector(".tt-body")!).height;

// 本文の高さが変わるまで待つ。**伸びるとは限らない**（読み込み中の枡より、
// 3 列に並んだ後の方が低い事がある）。
async function waitForHeight(h: Harness, before: number, least: number) {
  await vi.waitFor(() => expect(Math.abs(bodyHeight(h) - before)).toBeGreaterThan(least));
}

// ------------------------------------------------------------------
// 1. 高さが transaction 無しで変わる
// ------------------------------------------------------------------

test("画像の読み込みで本文が伸びても「+」が行に付いてくる", async () => {
  const h = (harness = await mount("image"));
  await waitForPlus(h);
  const before = bodyHeight(h);
  // 読み込みが終わると本文が伸びる。**transaction は 1 つも走らない。**
  const docBefore = JSON.stringify(h.doc());
  h.editor.setAttribute("assets", JSON.stringify([{ id: "asset-1", url: TALL_IMAGE }]));
  await waitForHeight(h, before, 20);
  await vi.waitFor(() => expect(plusOffset(h)).toBeLessThanOrEqual(3));
  expect(JSON.stringify(h.doc())).toBe(docBefore);
});

test("並べた画像の読み込みで本文が伸びても「+」が行に付いてくる", async () => {
  const h = (harness = await mount("gallery"));
  await waitForPlus(h);
  const before = bodyHeight(h);
  h.editor.setAttribute(
    "assets",
    JSON.stringify([1, 2, 3].map((one) => ({ id: `asset-${one}`, url: TALL_IMAGE })))
  );
  await waitForHeight(h, before, 20);
  await vi.waitFor(() => expect(plusOffset(h)).toBeLessThanOrEqual(3));
});

test("折り返しが増えて本文が伸びても「+」が行に付いてくる", async () => {
  const h = (harness = await mount("empty"));
  await typeText("おりかえしのふえる長い行を打ちます。".repeat(8));
  await userEvent.keyboard("{Enter}");
  await waitForPlus(h);
  const before = bodyHeight(h);
  // 窓を狭めると折り返しが増える。**doc は変わらない**（transaction は走らない）。
  await page.viewport(520, 900);
  await waitForHeight(h, before, 20);
  await vi.waitFor(() => expect((plusOffset(h) ?? 99) <= 3).toBe(true));
});

test("折り返しが減って本文が縮んでも「+」が行に付いてくる", async () => {
  await page.viewport(520, 900);
  const h = (harness = await mount("empty"));
  await typeText("おりかえしのへる長い行を打ちます。".repeat(8));
  await userEvent.keyboard("{Enter}");
  await waitForPlus(h);
  const before = bodyHeight(h);
  await page.viewport(1440, 900);
  await waitForHeight(h, before, 20);
  await vi.waitFor(() => expect((plusOffset(h) ?? 99) <= 3).toBe(true));
});

// ------------------------------------------------------------------
// 2. undo / redo
// ------------------------------------------------------------------

// 文の中の数式は、カーソルが乗っていない間だけ組版に化ける（`math.ts` の decoration）。
// **decoration は doc に入っていない**ので、doc が戻っても描き直されるとは限らない。
const mathParts = (h: Harness) => h.editor.querySelectorAll(".tt-math-src, .tt-math-out").length;

async function withMath(h: Harness) {
  await typeText("$x$ あと");
  await settle();
  await vi.waitFor(() => expect(mathParts(h)).toBeGreaterThan(0));
}

test("undo と redo の後も、文の中の数式の decoration が残る", async () => {
  const h = (harness = await mount("empty"));
  await withMath(h);
  const before = { doc: JSON.stringify(h.doc()), parts: mathParts(h) };
  await userEvent.keyboard("{Meta>}z{/Meta}");
  await settle();
  await userEvent.keyboard("{Meta>}{Shift>}z{/Shift}{/Meta}");
  await settle();
  await vi.waitFor(() => expect(JSON.stringify(h.doc())).toBe(before.doc));
  expect(mathParts(h)).toBe(before.parts);
});

test("undo と redo の後も「+」が行に付いてくる", async () => {
  const h = (harness = await mount("empty"));
  await typeText("あいうえお");
  await userEvent.keyboard("{Enter}");
  await waitForPlus(h);
  await userEvent.keyboard("{Meta>}z{/Meta}");
  await settle();
  await userEvent.keyboard("{Meta>}{Shift>}z{/Shift}{/Meta}");
  await settle();
  await waitForPlus(h);
  expect((plusOffset(h) ?? 99) <= 3).toBe(true);
});

// ------------------------------------------------------------------
// 3. 外から doc 属性で新しい内容が来た
// ------------------------------------------------------------------

const INCOMING = {
  type: "doc",
  content: [
    { type: "paragraph", content: [{ type: "text", marks: [{ type: "math" }], text: "E = mc^2" }] },
    { type: "paragraph" },
  ],
};

test("外から doc が来た後も、文の中の数式の decoration が出る", async () => {
  const h = (harness = await mount("empty"));
  await typeText("まえの中身");
  h.editor.setAttribute("doc", JSON.stringify(INCOMING));
  await settle();
  await vi.waitFor(() => expect(h.text()).toBe("E = mc^2"));
  await vi.waitFor(() => expect(mathParts(h)).toBeGreaterThan(0));
});

test("外から doc が来た後も「+」が行に付いてくる", async () => {
  const h = (harness = await mount("empty"));
  await typeText("まえの中身");
  h.editor.setAttribute("doc", JSON.stringify(INCOMING));
  await settle();
  await vi.waitFor(() => expect(h.text()).toBe("E = mc^2"));
  await waitForPlus(h);
  expect((plusOffset(h) ?? 99) <= 3).toBe(true);
});

// ------------------------------------------------------------------
// 4. 見つけた帯すべてで、押して打っても doc が変わらない
// ------------------------------------------------------------------

// その場に出ている帯を**class で拾う**。`ui.ts` の `bar()` が付ける物と、
// 手で組んである表の帯（`tiptap-editor.ts` の `tableBar`）。
const BAR_SELECTOR = `.${BAR_CLASS}, .tt-code-bar, .tt-tablebar`;

function visibleBars(h: Harness): HTMLElement[] {
  return [...h.editor.querySelectorAll<HTMLElement>(BAR_SELECTOR)].filter(
    (bar) => !bar.hidden && box(bar).height > 0 && box(bar).width > 0
  );
}

// 帯の余白（中の欄にもボタンにも当たらない点）。
//
// **「帯そのもの」に限らない。** 帯の中に置いた入れ物（`tt-tablebar-left` のような
// 並べるだけの div）は欄でもボタンでもないので、そこも余白として扱う。
const CONTROL = "input, textarea, select, button, a, [contenteditable='true']";
function gapOf(bar: HTMLElement): number | null {
  const area = box(bar);
  const y = area.top + area.height / 2;
  for (let x = area.left + 3; x < area.right - 3; x += 2) {
    const hit = document.elementFromPoint(x, y);
    if (!hit || !bar.contains(hit)) continue;
    let control = false;
    for (let node: Element | null = hit; node && node !== bar; node = node.parentElement)
      if (node.matches(CONTROL)) control = true;
    if (!control) return x - area.left;
  }
  return null;
}

function pickNode(h: Harness, name: string) {
  const view = inner(h);
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  if (found >= 0) view.commands.setNodeSelection(found);
}

function caretIn(h: Harness, name: string) {
  const view = inner(h);
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  view.commands.focus();
  if (found >= 0) view.commands.setTextSelection(found + 2);
}

// [名前, 初期状態, 帯を出す]
const SURFACES: Array<[string, string, (h: Harness) => Promise<void> | void]> = [
  ["コード", "parts", (h) => caretIn(h, "codeBlock")],
  ["数式", "parts", (h) => pickNode(h, "mathBlock")],
  ["リンクカード", "parts", (h) => pickNode(h, "linkCard")],
  ["画像", "image", (h) => pickNode(h, "imageItem")],
  ["並べた画像", "gallery", (h) => pickNode(h, "imageItem")],
  // 表の帯は表の 26px 上に出るので、**上に行のある表**で見る（一番上だと
  // 貼り付くツールバーの下に隠れて、押す事すらできない）。
  ["表", "table-between", (h) => caretIn(h, "tableCell")],
];

for (const [name, fixture, reveal] of SURFACES) {
  test(`${name}の帯の余白を押して打っても doc が変わらない`, async () => {
    const h = (harness = await mount(fixture));
    await reveal(h);
    await settle();
    await vi.waitFor(() => expect(visibleBars(h).length).toBeGreaterThan(0));

    const before = JSON.stringify(h.doc());
    let pressed = 0;
    for (const bar of visibleBars(h)) {
      const gap = gapOf(bar);
      if (gap === null) continue;
      await userEvent.click(bar, { position: { x: Math.round(gap), y: Math.round(box(bar).height / 2) } });
      await settle();
      await userEvent.keyboard("zzzz");
      await settle();
      pressed += 1;
    }
    expect({ pressed: pressed > 0, doc: JSON.stringify(h.doc()) }).toEqual({ pressed: true, doc: before });
  });
}

// 引用には帯が無い。**出典の行は押すと出典を作って入る場所**なので、
// 「押して打つと出典に入り、引用の本文は変わらない」を同じ横断として見る。
test("引用の出典の行を押して打っても、引用の本文は変わらない", async () => {
  const h = (harness = await mount("quote"));
  // 行は mousedown で出典に入る（`quote-node.ts`）。押す側もそれに合わせる。
  press(h.editor.querySelector<HTMLElement>(".tt-quote-cite-row")!);
  await settle();
  await userEvent.keyboard("zzzz");
  await settle();
  const quoted = (h.doc() as any).content[0].content[0].content[0].text;
  expect(quoted).toBe("引用された文章がここに入ります。");
});

// 「+」は行の文字に重ならない。
//
// **重なると「カーソルが消えた」ように見える。** 「+」は円で描くので、行頭のカーソルが
// 円の縁と重なると見分けが付かない（実際に見分けが付かなかった）。note は帯を置いて
// 余白を取っている。ここでは重なっていない事だけを見る。
for (const fixture of ["image-between", "long", "parts"]) {
  test(`${fixture}: 「+」が行の文字に重ならない`, async () => {
    const h = (harness = await mount(fixture));
    inner(h).commands.focus("end");
    await settle();
    const plus = h.editor.querySelector<HTMLElement>(".tt-plus")!;
    if (plus.hidden) return expect(plus.hidden).toBe(true);
    const line = inner(h).view.coordsAtPos(inner(h).state.selection.from);
    expect(Math.round(line.left - box(plus).right)).toBeGreaterThanOrEqual(8);
  });
}
