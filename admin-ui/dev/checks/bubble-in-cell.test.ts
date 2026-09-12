// 表のセルの中でも、文字を選んだら装飾の帯が出る事。
//
// **doc はセルの中のマークを許している**（`RichText.checkCellChildren` はブロックだけを断り、
// 段落の中の text には普通のマークの許可リストが効く）。Markdown も往復する。画面から付ける
// 手段だけが無いと、比較表の「詳細はこちら」のリンクが張れない。
//
// WhyNot: コードブロックは出さないまま。中身はプレーンテキストでマークが付かない。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const inner = (h: Harness) => (h.editor as any).editor;
const bubble = (h: Harness) => h.editor.querySelector(".tt-bubble");

/** n 番目のセルの中の文字を選ぶ。 */
async function pickInCell(h: Harness, index: number) {
  const view = inner(h);
  const spots: number[] = [];
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") spots.push(pos);
  });
  view.commands.focus();
  view.commands.setTextSelection(spots[index] + 2);
  await settle();
  await userEvent.keyboard("たいじ");
  h.selectBack(3);
  await settle();
}

test("表のセルの中で文字を選ぶと帯が出る", async () => {
  const h = (harness = await mount("table"));
  await pickInCell(h, 0);
  await vi.waitFor(() => expect(bubble(h)).not.toBeNull());
  expect(bubble(h)).not.toBeNull();
});

test("セルを跨いで選んだ時は帯を出さない", async () => {
  const h = (harness = await mount("table"));
  const view = inner(h);
  const spots: number[] = [];
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") spots.push(pos);
  });
  view.commands.focus();
  // セルを跨ぐ選択は prosemirror-tables の CellSelection になる。
  view.commands.setCellSelection({ anchorCell: spots[0], headCell: spots[1] });
  await settle();
  await new Promise((done) => window.setTimeout(done, 160));
  expect(bubble(h)).toBeNull();
});

test("コードブロックの中で文字を選んでも帯は出さない", async () => {
  const h = (harness = await mount("code"));
  const view = inner(h);
  let at = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "codeBlock" && at < 0) at = pos + 1;
  });
  view.commands.focus();
  view.commands.setTextSelection({ from: at, to: at + 3 });
  await settle();
  await new Promise((done) => window.setTimeout(done, 160));
  expect(bubble(h)).toBeNull();
});
