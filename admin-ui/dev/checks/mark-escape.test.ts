// 掛けた装飾から抜ける道（`web/mark-escape.ts`）。
//
// 抜ける道は 3 つ: **→ キー / Space 2 回 / ボタンをもう一度**。どれも「箱の右端に立った
// カーソルから外へ出る」同じ形で、段落を変えた時は黙って落ちる（リストの中では残る）。
//
// 抜けたかどうかは**次に打った 1 文字に乗ったマーク**で見る。storedMarks は
// 入力規則が消した後だと空になり、抜けたのか掛かっていないのか区別できない。
// 本文は docs/design/editor-dom-parts.md の「マークの抜け方」。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, toEnd, lineAt, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 文字を選んで帯の道具で掛けた形を作る。**掛けた直後は storedMarks が立たない**ので、
// TipTap の `exitable` が動かない（帯の道具は選ばないと押せないため、必ずこの形になる）。
async function marked(name: string): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  h.apply(name);
  return h;
}

// 今打った文字を左へ選んでから掛ける。**実機で帯の道具を押せる唯一の形**。
async function typedThenMarked(text: string, name: string): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard(text);
  h.selectBack(text.length);
  h.apply(name);
  return h;
}

test("→ キーでコードの箱から出る", async () => {
  const h = await marked("code");
  await userEvent.keyboard("abc");
  expect(h.lastMarks()).toContain("code");
  await userEvent.keyboard("{ArrowRight}x");
  expect(h.lastMarks()).not.toContain("code");
});

test("Space 2 回でコードの箱から出る。1 つ目は中に残る", async () => {
  const h = await marked("code");
  await userEvent.keyboard("a b");
  expect(h.text()).toContain("a b");
  expect(h.lastMarks()).toContain("code");
  await userEvent.keyboard("  x");
  expect(h.lastMarks()).not.toContain("code");
});

test("下線でも同じ道で抜けられる", async () => {
  const h = await marked("underline");
  await userEvent.keyboard("abc");
  expect(h.lastMarks()).toContain("underline");
  await userEvent.keyboard("{ArrowRight}x");
  expect(h.lastMarks()).not.toContain("underline");
});

test("Enter で段落を変えると装飾が落ちる", async () => {
  const h = await marked("underline");
  await userEvent.keyboard("abc{Enter}x");
  expect(h.lastMarks()).not.toContain("underline");
});

test("リストの項目を増やす時は装飾が残る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("- こうもく");
  h.selectBack(4);
  h.apply("bold");
  h.collapseRight();
  await userEvent.keyboard("{Enter}つぎ");
  expect(h.lastMarks()).toContain("bold");
});

for (const [name, mark, word] of [
  ["コード（文の中）", "code", "code"],
  ["数式（文の中）", "math", "x^2"],
] as const) {
  test(`選んでボタンを押した直後の → キーで ${name} の箱から出る`, async () => {
    const h = await typedThenMarked(word, mark);
    await userEvent.keyboard("{ArrowRight}そと");
    expect(lineAt(h, 0)).toBe(`${word}[${mark}] そと[なし]`);
  });

  test(`行末に畳んでからの → キーで ${name} の箱から出る`, async () => {
    const h = await typedThenMarked(word, mark);
    h.collapseRight();
    await userEvent.keyboard("{ArrowRight}そと");
    expect(lineAt(h, 0)).toBe(`${word}[${mark}] そと[なし]`);
  });
}

test("Space 1 回では抜けない（箱の中に空白が入る）", async () => {
  const h = await typedThenMarked("code", "code");
  h.collapseRight();
  await userEvent.keyboard(" ");
  expect(lineAt(h, 0)).toBe("code [code]");
});

test("Space 2 回でインラインコードの箱から出る", async () => {
  const h = await typedThenMarked("code", "code");
  h.collapseRight();
  await userEvent.keyboard("  そと");
  expect(lineAt(h, 0)).toBe("code [code]  そと[なし]");
});

test("ボタンをもう一度押すと装飾が外れる", async () => {
  const h = await typedThenMarked("code", "code");
  h.apply("code");
  expect(lineAt(h, 0)).toBe("code[なし]");
});
