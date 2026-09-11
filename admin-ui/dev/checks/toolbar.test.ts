// 道具の置き場（`docs/design/toolbar-split-mock.html` の案 D）。
//
// ヘッダは押すだけで入る物、浮く帯は文字に掛ける物 6 個 +「…」、ブロックを入れる口は
// 「+」の一覧。**どこに何があるか**だけを見る（位置と溢れは遅い層）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 浮く帯は tippy が `document.body` に付けるので、エディタの要素の外も見る。
const titles = (h: Harness, selector: string) =>
  [...document.querySelectorAll<HTMLElement>(selector)]
    .filter((one) => !one.hidden)
    .map((one) => one.getAttribute("title") ?? "");

// 文字を選んで浮く帯を出す。
async function withSelection(): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("たいじ");
  h.selectBack(3);
  // 帯は選んでから 80ms 後に出る（BubbleMenu の updateDelay）。**出るまで待つ**。
  await vi.waitFor(() => expect(document.querySelector(".tt-bubble")).not.toBeNull());
  return h;
}

test("ヘッダに段落の種類のドロップダウンが 1 つ", async () => {
  const h = (harness = await mount("empty"));
  expect(h.editor.querySelectorAll(".tt-bar .tt-block")).toHaveLength(1);
});

test("ヘッダは 段落の種類 / 画像 / 箇条書き / 番号付き / 元に戻す / やり直す の 6 個", async () => {
  const h = (harness = await mount("empty"));
  expect(titles(h, "tiptap-editor .tt-bar .tt-tool")).toEqual(["画像", "箇条書き", "番号付き", "元に戻す（⌘Z）", "やり直す（⇧⌘Z）"]);
});

test("下線と表はヘッダに出さない", async () => {
  const h = (harness = await mount("empty"));
  expect(titles(h, "tiptap-editor .tt-bar .tt-tool").filter((title) => title === "下線" || title === "表")).toEqual([]);
});

test("浮く帯は 文字に掛ける 6 個 +「…」", async () => {
  const h = await withSelection();
  const tools = [...document.querySelectorAll<HTMLElement>(".tt-bubble > .tt-bubble-tool")]
    .filter((tool) => !tool.hidden)
    .map((tool) => tool.getAttribute("title"));
  expect(tools).toEqual(["太字", "斜体", "打ち消し", "コード（文の中）", "数式（文の中）", "リンク", "その他の書式"]);
});

test("「…」の中は「文字」の 1 組だけ", async () => {
  const h = await withSelection();
  const groups = [...document.querySelectorAll(".tt-more-pop .tt-more-group")].map((one) => one.textContent);
  expect(groups).toEqual(["文字"]);
});

test("「…」に畳んだのは 下線 / 蛍光ペン / 上付き / 下付き の 4 つ", async () => {
  const h = await withSelection();
  const items = [...document.querySelectorAll<HTMLElement>(".tt-more-pop .tt-more-item")].map((one) => one.dataset.more);
  expect(items).toEqual(["下線", "蛍光ペン", "上付き", "下付き"]);
});

test("「…」の中の下線に、掛かっている印が付く", async () => {
  const h = await withSelection();
  h.apply("underline");
  document.querySelector<HTMLElement>(".tt-bubble .tt-more")!.click();
  await settle();
  expect(document.querySelector('.tt-more-item[data-more="下線"]')!.classList.contains("is-on")).toBe(true);
});

test("「…」は Esc で閉じる", async () => {
  const h = await withSelection();
  document.querySelector<HTMLElement>(".tt-bubble .tt-more")!.click();
  await settle();
  expect((document.querySelector(".tt-more-pop") as HTMLElement).hidden).toBe(false);
  await userEvent.keyboard("{Escape}");
  await settle();
  expect((document.querySelector(".tt-more-pop") as HTMLElement).hidden).toBe(true);
});

test("ブロックを入れる口は「+」の一覧に揃っている", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  h.editor.querySelector<HTMLElement>(".tt-plus")!.click();
  await settle();
  const items = [...h.editor.querySelectorAll(".tt-blocks .tt-blocks-item")].map((one) => one.textContent?.trim());
  expect(items).toEqual(["画像", "区切り線", "引用", "コード", "表", "数式", "チェックリスト", "埋め込み"]);
});
