// 画像を続けて入れた時に、前の 1 枚が残る事（`blockInsertPoint`）。
//
// メディアの画面を開くと疑似行が消え、選択が直前の画像のキャプションへ戻る。
// そこへ入れると TipTap の「空の textblock は入れた物で置き換える」に当たり、
// 1 枚目の `assetId` ごと消えていた。
import { expect, test, afterEach } from "vitest";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const assetIds = (h: Harness): string[] => {
  const found: string[] = [];
  const walk = (node: any) => {
    if (node?.type === "imageItem" && node.attrs?.assetId) found.push(node.attrs.assetId);
    for (const child of node?.content ?? []) walk(child);
  };
  walk(h.doc());
  return found;
};

// Elm が渡す `insert` の属性。**1 拍おいて効く**ので待つ
// （属性が変わるのは Elm が DOM を書いている最中なので、その場では入れない）。
async function insert(h: Harness, seq: number, ids: string[]) {
  h.editor.setAttribute("insert", JSON.stringify({ seq, assetIds: ids }));
  await new Promise((done) => window.setTimeout(done, 0));
}

test("キャプションにカーソルがある時に入れても 1 枚目が残る", async () => {
  const h = (harness = await mount("image"));
  h.caretInCaption();
  await insert(h, 1, ["asset-2"]);
  expect(assetIds(h)).toEqual(["asset-1", "asset-2"]);
});

test("本文の空段落から入れた時は、その段落を置き換えて空行を残さない", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, 1, ["asset-1"]);
  expect(assetIds(h)).toEqual(["asset-1"]);
  expect(h.names().filter((name) => name === "paragraph")).toHaveLength(0);
});
