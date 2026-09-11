// 引用の出典の行の置き所。
//
// 出典は node view の中（contentDOM の外）にあるので、引用の箱の高さにこの行が
// 入っていないと次のブロックがこの行の上に乗る。次に来るブロックの種類ごとに測る。
//
// 出典に何が入るか（quoteCite の中身・マーク・矢印の行き先）は `quote.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

const NEXT: Record<string, unknown> = {
  数式: { type: "mathBlock", attrs: { tex: "\\sum_{i=1}^{n} \\frac{x_i^2}{\\sqrt{y_i}}" } },
  段落: { type: "paragraph", content: [{ type: "text", text: "次の段落" }] },
  画像: { type: "image", content: [{ type: "imageItem", attrs: { assetId: "asset-1" } }] },
  コード: { type: "codeBlock", attrs: { language: "javascript" }, content: [{ type: "text", text: "const a = 1;" }] },
  引用: {
    type: "blockquote",
    content: [
      { type: "paragraph", content: [{ type: "text", text: "つぎのいんよう" }] },
      { type: "quoteCite", content: [{ type: "text", text: "つぎのしゅってん" }] },
    ],
  },
};

const docWith = (cite: string | null, next: unknown) => ({
  type: "doc",
  content: [
    {
      type: "blockquote",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "ひきよう" }] },
        ...(cite ? [{ type: "quoteCite", content: [{ type: "text", text: cite }] }] : []),
      ],
    },
    next,
    { type: "paragraph", content: [{ type: "text", text: "おわり" }] },
  ],
});

test("出典は引用の箱の外の下、右に出る", async () => {
  const h = (harness = await mount("quote"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-quote-cite-row")).not.toBeNull());
  const quote = box(at(h, ".tt-quote blockquote"));
  const row = box(at(h, ".tt-quote-cite-row"));
  expect({ below: row.top >= quote.bottom - 1, right: row.right >= quote.right - 4 }).toEqual({ below: true, right: true });
});

for (const [kind, next] of Object.entries(NEXT)) {
  for (const cite of ["しゅってん", null]) {
    test(`引用の出典の行が次のブロック（${kind}・出典${cite ? "あり" : "なし"}）に重ならない`, async () => {
      const h = (harness = await mount(docWith(cite, next)));
      await vi.waitFor(() => expect(h.editor.querySelector(".tt-body .tt-quote")).not.toBeNull());
      await settle();
      const quote = at(h, ".tt-body .tt-quote");
      // 出典は箱に重ねて置くので、下端は出典（あれば）か、場所を空けている行で測る。
      const above = quote.querySelector("blockquote > cite") ?? quote.querySelector(".tt-quote-cite-row")!;
      const gap = box(above).bottom - box(quote.nextElementSibling!).top;
      expect(gap <= 0).toBe(true);
    });
  }
}
