// 画像のキャプションから上下の矢印で、画像の外の行へ出る。
//
// 出た先は本文の段落。中に入れないブロックを矢印で越えた時は、その手前・その先に
// 疑似行が立つ（`web/block-edges.ts`）ので、行の中身ではなく**画像より前か後か**で見る。
//
// キャプションに何が入るか（imageItem の content）は `image.test.ts`。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// カーソルの行の種類と、画像より前か後か。
function whereAt(h: Harness): { kind: string; side: string } {
  const view = (h.editor as any).editor;
  let image = -1;
  let size = 0;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "image" && image < 0) {
      image = pos;
      size = node.nodeSize;
    }
  });
  const caret = view.state.selection.from;
  return {
    kind: view.state.selection.$from.parent.type.name,
    side: caret < image ? "前" : caret > image + size ? "後" : "画像の中",
  };
}

for (const [key, where] of [
  ["ArrowUp", "前"],
  ["ArrowDown", "後"],
] as const) {
  test(`キャプションから ${key} で画像の${where}の行へ出る`, async () => {
    const h = (harness = await mount("image-between"));
    h.caretInCaption();
    await settle();
    await userEvent.keyboard(`{${key}}`);
    await settle();
    expect(whereAt(h)).toEqual({ kind: "paragraph", side: where });
  });
}
