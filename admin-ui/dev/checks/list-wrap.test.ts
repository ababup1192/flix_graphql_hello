// リストの項目の中で Shift+Enter した 2 行目が、1 行目の文字の左端と揃う。
//
// 行の箱は Range から測る（折り返した行ごとの矩形が出る）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 一覧の項目から入れる物（チェックリスト）と、ヘッダの道具から入れる物。
async function start(h: Harness, title: string) {
  toEnd(h);
  await settle();
  if (title === "チェックリスト") {
    h.editor.querySelector<HTMLElement>(".tt-plus")!.click();
    await settle();
    press([...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find((one) => one.textContent?.trim() === title)!);
  } else {
    h.editor.querySelector<HTMLElement>(`.tt-bar .tt-tool[title="${title}"]`)!.click();
  }
  await settle();
}

// 項目の中の段落の、折り返した行ごとの左端。
function leftsOf(h: Harness): number[] {
  const line = h.editor.querySelector(".tt-body li p")!;
  const range = document.createRange();
  range.selectNodeContents(line);
  return [...range.getClientRects()].filter((one) => one.width > 0).map((one) => Math.round(one.left * 100) / 100);
}

for (const title of ["チェックリスト", "箇条書き", "番号付き"]) {
  test(`${title}の項目の 2 行目が 1 行目と揃う`, async () => {
    const h = (harness = await mount("empty"));
    await start(h, title);
    await userEvent.keyboard("一行目");
    await userEvent.keyboard("{Shift>}{Enter}{/Shift}");
    await userEvent.keyboard("二行目");
    await vi.waitFor(() => expect(leftsOf(h)).toHaveLength(2));
    const [first, second] = leftsOf(h);
    expect(Math.abs(first - second) < 0.5).toBe(true);
  });
}
