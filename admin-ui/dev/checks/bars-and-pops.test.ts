// 帯と浮く面の横断の確認（部品は `web/ui.ts`）。
//
// ブロックごとに書かず、**すべての帯とすべての面**を同じ物差しで見る。
//   - 帯の余白: 押してもキャレットが出ず、打っても帯に入らない
//   - 浮く面: 画面からも本文の枠からも出ず、本文を送っても基準の欄に付いたまま
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  window.scrollTo(0, 0);
});

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

// 帯の余白（中の欄にもボタンにも当たらない点）。
function gapOf(bar: HTMLElement): { x: number; y: number } | null {
  const area = box(bar);
  if (bar.hidden || area.height === 0) return null;
  const y = area.top + area.height / 2;
  for (let x = area.left + 3; x < area.right - 3; x += 2) {
    if (document.elementFromPoint(x, y) === bar) return { x, y };
  }
  return null;
}

// その種類の node を 1 つ選ぶ（帯は選んだ時だけ出る物がある）。
function pickNode(h: Harness, name: string) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  if (found >= 0) view.commands.setNodeSelection(found);
}

// 浮く面が画面と本文の枠に収まっているか。
function popOf(h: Harness, selector: string) {
  const el = h.editor.querySelector<HTMLElement>(selector);
  if (!el || el.hidden) return null;
  const area = box(el);
  const body = box(at(h, ".tt-body"));
  return {
    inScreen: area.top >= 0 && area.bottom <= window.innerHeight && area.left >= 0 && area.right <= window.innerWidth,
    inBody: area.bottom <= body.bottom + 1,
  };
}

for (const [name, selector, node] of [
  ["コード", ".tt-code-bar", null],
  ["数式", ".tt-mathblock .tt-block-bar", "mathBlock"],
  ["リンクカード", ".tt-link-card .tt-block-bar", "linkCard"],
] as const) {
  test(`${name}の帯の余白を押してもキャレットが出ず、打っても帯に入らない`, async () => {
    const h = (harness = await mount("parts"));
    if (node) pickNode(h, node);
    await vi.waitFor(() => expect(gapOf(at(h, selector))).not.toBeNull());
    const bar = at(h, selector);
    const gap = gapOf(bar)!;
    const area = box(bar);
    // **余白そのものを押す。** 要素の真ん中を押すと中の欄に当たり、何を見ているか変わる。
    await userEvent.click(bar, { position: { x: Math.round(gap.x - area.left), y: Math.round(area.height / 2) } });
    await settle();
    const picked = window.getSelection();
    const caret = !!picked && picked.rangeCount > 0 && !!picked.anchorNode && bar.contains(picked.anchorNode);
    await userEvent.keyboard("zzzz");
    await settle();
    expect({ caret, bar: (h.editor.querySelector(selector)?.textContent ?? "").includes("zzzz") }).toEqual({
      caret: false,
      bar: false,
    });
  });
}

// 選んだ塊の帯の余白を押した後に打っても、塊が打った文字に置き換わらない。
//
// **帯の余白を押した時点で焦点が帯へ移る**（`ui.ts` の `bar`）ので、次の打鍵は本文に届かない。
// 消すのは Backspace / Delete と帯の削除だけ。
const WITH_BAR = [
  ["数式", ".tt-mathblock .tt-block-bar", "mathBlock"],
  ["リンクカード", ".tt-link-card .tt-block-bar", "linkCard"],
  ["画像", ".tt-image .tt-block-bar", "imageItem"],
] as const;

const WITH_BAR_DOC = {
  type: "doc",
  content: [
    { type: "paragraph", content: [{ type: "text", text: "まえの行" }] },
    { type: "mathBlock", attrs: { tex: "E = mc^2" } },
    { type: "linkCard", attrs: { url: "https://example.com/parts" } },
    { type: "image", content: [{ type: "imageItem", attrs: { assetId: "asset-1" } }] },
    {
      type: "codeBlock",
      attrs: { language: "javascript", fileName: null, highlightLines: null },
      content: [{ type: "text", text: "const a = 1" }],
    },
    { type: "paragraph" },
  ],
};

for (const [name, selector, node] of WITH_BAR) {
  test(`${name}の帯の余白を押した後に打っても${name}が消えない`, async () => {
    const h = (harness = await mount(WITH_BAR_DOC));
    pickNode(h, node);
    await vi.waitFor(() => expect(gapOf(at(h, selector))).not.toBeNull());
    const bar = at(h, selector);
    const gap = gapOf(bar)!;
    const area = box(bar);
    await userEvent.click(bar, { position: { x: Math.round(gap.x - area.left), y: Math.round(area.height / 2) } });
    await settle();
    await userEvent.keyboard("zzzz");
    await settle();
    expect({ node: h.names().includes(node), text: h.text().includes("zzzz") }).toEqual({ node: true, text: false });
  });
}

test("言語の候補が画面と本文の枠に収まる", async () => {
  const h = (harness = await mount("parts"));
  await userEvent.click(at(h, ".tt-code-lang"));
  await vi.waitFor(() => expect(popOf(h, ".tt-code-pop")).not.toBeNull());
  expect(popOf(h, ".tt-code-pop")).toEqual({ inScreen: true, inBody: true });
});

// **本当に送れる長さの本文で見る。** 短い本文では送れず、ずれようが無い。
test("本文を送っても言語の候補が欄に付いたまま", async () => {
  const h = (harness = await mount("long"));
  await userEvent.click(at(h, ".tt-code-lang"));
  await vi.waitFor(() => expect(popOf(h, ".tt-code-pop")).not.toBeNull());
  const offset = () => Math.round(box(at(h, ".tt-code-pop")).top - box(at(h, ".tt-code-lang")).bottom);
  const before = offset();
  window.scrollBy(0, 150);
  await vi.waitFor(() => expect(window.scrollY).toBeGreaterThan(0));
  await vi.waitFor(() => expect(Math.abs(before - offset()) <= 1).toBe(true));
});

test("一番下の段落でもブロックの一覧が画面と本文の枠に収まる", async () => {
  const h = (harness = await mount("parts"));
  (h.editor as any).editor.commands.focus("end");
  await settle();
  at(h, ".tt-plus").click();
  await vi.waitFor(() => expect(popOf(h, ".tt-blocks")).not.toBeNull());
  expect(popOf(h, ".tt-blocks")).toEqual({ inScreen: true, inBody: true });
});

test("一番下の段落でも埋め込みの URL の面が画面と本文の枠に収まる", async () => {
  const h = (harness = await mount("parts"));
  (h.editor as any).editor.commands.focus("end");
  await settle();
  at(h, ".tt-plus").click();
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-blocks-item").length).toBeGreaterThan(0));
  press([...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find((one) => one.textContent?.includes("埋め込み"))!);
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-blocks input")).not.toBeNull());
  expect(popOf(h, ".tt-blocks")).toEqual({ inScreen: true, inBody: true });
});
