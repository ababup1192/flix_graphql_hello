// 数式（`docs/design/richtext-math-ui.md`）。
//
// 普段は組版だけ、箱のどこを押しても TeX の欄、掴みで選ぶと削除の帯。
// 見るのは doc と焦点の行き先だけ（ホバーで出る削除の濃さや当たり判定は `math-layout.test.ts`）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const focused = () => String(document.activeElement?.className ?? "").split(" ")[0];
// **この画面の欄**に焦点があるか。名前だけで見ると、前の検査が残した同名の欄に当たる。
const inTexBox = (h: Harness) => document.activeElement === at(h, ".tt-mathblock-src");
const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const kinds = (h: Harness) => ((h.doc() as any).content ?? []).map((node: any) => node.type);
const texOf = (h: Harness) =>
  ((h.doc() as any).content ?? []).find((node: any) => node.type === "mathBlock")?.attrs?.tex ?? null;

// TeX の欄に入れる。
//
// WhyNot: ここだけ打鍵で入れない。欄は 1 打鍵ごとに doc を書き直し、その度に node view の
// `update` が走って欄の中身を doc の値で戻す。速い打鍵はその往復に追い越され、数文字で
// 止まる（実際に "E" だけ残った）。**焦点が欄に来る所までは打鍵で見て**（別の検査）、
// 中身は欄そのものの口（value + input）で入れる。
async function typeTex(h: Harness, tex: string) {
  const box = at<HTMLTextAreaElement>(h, ".tt-mathblock-src");
  box.focus();
  box.value = tex;
  box.dispatchEvent(new Event("input", { bubbles: true }));
  await settle();
}

// `$$` + Enter で入れて、TeX を打つ。
async function byDollars(tex: string): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("$${Enter}");
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await typeTex(h, tex);
  return h;
}

test("$$ の直後に TeX の欄へ焦点が入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("$${Enter}");
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
});

test("$$ の直後に打った TeX が数式に入る", async () => {
  const h = await byDollars("E = mc^2");
  await vi.waitFor(() => expect(texOf(h)).toBe("E = mc^2"));
});

test("普段は TeX の欄が隠れ、組版された数式が出る", async () => {
  const h = (harness = await mount("math"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-mathblock .katex").length).toBeGreaterThan(0));
  expect(at(h, ".tt-mathblock-src").hidden).toBe(true);
});

test("組版を押すと TeX の欄が開いて焦点が入る", async () => {
  const h = (harness = await mount("math"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  expect(at(h, ".tt-mathblock-src").hidden).toBe(false);
});

test("1 行目の ↑ で TeX の欄から前の行へ出る", async () => {
  const h = (harness = await mount("math"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await userEvent.keyboard("{ArrowUp}");
  await vi.waitFor(() => expect(focused()).not.toBe("tt-mathblock-src"));
});

test("最終行の ↓ で TeX の欄から次の行へ出る", async () => {
  const h = (harness = await mount("math"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await userEvent.keyboard("{ArrowDown}");
  await vi.waitFor(() => expect(focused()).not.toBe("tt-mathblock-src"));
});

test("欄の中の Esc で数式を選んだ状態になり、TeX の欄が閉じる", async () => {
  const h = (harness = await mount("math"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await userEvent.keyboard("{Escape}");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-mathblock.ProseMirror-selectednode")).toHaveLength(1));
  expect(at(h, ".tt-mathblock-src").hidden).toBe(true);
});

test("数式の帯は削除だけ", async () => {
  const h = (harness = await mount("math"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await userEvent.keyboard("{Escape}");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-mathblock.ProseMirror-selectednode")).toHaveLength(1));
  const tools = [...h.editor.querySelectorAll(".tt-mathblock .tt-image-bar .tt-image-tool")].map((one) =>
    one.getAttribute("aria-label"),
  );
  expect(tools).toEqual(["削除"]);
});

test("右上の削除で数式が消え、段落だけが残る", async () => {
  const h = (harness = await mount("math"));
  const corner = at(h, ".tt-mathblock .tt-block-corner");
  expect(corner.getAttribute("aria-label")).toBe("削除");
  await userEvent.click(corner);
  await vi.waitFor(() => expect(kinds(h)).not.toContain("mathBlock"));
  expect([...new Set(kinds(h))]).toEqual(["paragraph"]);
});

test("空の TeX の欄の Backspace で数式が消え、段落に続きが打てる", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("$${Enter}");
  await vi.waitFor(() => expect(inTexBox(h)).toBe(true));
  await settle();
  await userEvent.keyboard("{Backspace}");
  await vi.waitFor(() => expect(kinds(h)).not.toContain("mathBlock"));
  await userEvent.keyboard("もどった");
  await settle();
  expect(h.text()).toContain("もどった");
});

test("「+」の一覧の「数式」でブロックの数式が入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  at(h, ".tt-plus").click();
  await settle();
  const item = [...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find(
    (one) => one.textContent?.trim() === "数式",
  )!;
  press(item);
  await vi.waitFor(() => expect(kinds(h)).toContain("mathBlock"));
});

test("浮く帯の数式で文中の数式が入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("速さはx");
  h.selectBack(1);
  h.apply("math");
  await userEvent.keyboard("E = mc^2");
  await settle();
  expect(h.lastMarks()).toContain("math");
  expect(h.text()).toContain("E = mc^2");
});
