// 結合したセルのある表を組み直した時に、結合が残るか・割れるか。
//
// 升の数や寄せは `table.test.ts`、帯と掴みは `table-layout.test.ts`。
import { expect, test, afterEach } from "vitest";
import { TableMap } from "@tiptap/pm/tables";
import { mount, settle, type Harness } from "../harness";
import { moveColumn, moveRow, resizeTable } from "../../web/table-tools";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const inner = (h: Harness) => (h.editor as any).editor;

// 最初の升の中にカーソルを置く。表の道具はカーソルのある表を相手にする。
function caretInCell(h: Harness) {
  const view = inner(h);
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableHeader" && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + 2);
}

// 表を「行ごとの `中身:colspan×rowspan`」で読む。
function shape(h: Harness): string[][] {
  const table = ((h.doc() as any).content ?? []).find((node: any) => node.type === "table");
  return table.content.map((row: any) =>
    row.content.map((cell: any) => `${cell.content?.[0]?.content?.[0]?.text ?? ""}:${cell.attrs.colspan}×${cell.attrs.rowspan}`),
  );
}

// 表の形が壊れていないか。TableMap が不整合を挙げず、行ごとの幅（結合と覆いを足した数）が
// 全部同じか。
function sound(h: Harness): { size: string; problems: unknown; widths: number[] } {
  const view = inner(h);
  let table: any = null;
  view.state.doc.descendants((node: any) => {
    if (node.type.name === "table" && !table) table = node;
  });
  const map = TableMap.get(table);
  const carry: number[] = [];
  const widths = shape(h).map((line, row) => {
    const covered = carry.filter((until) => until >= row).length;
    const own = line.reduce((sum, one) => {
      const [colspan, rowspan] = one.split(":")[1].split("×").map(Number);
      for (let each = 0; each < colspan; each += 1) carry.push(row + rowspan - 1);
      return sum + colspan;
    }, 0);
    return own + covered;
  });
  return { size: `${map.height}×${map.width}`, problems: (map as any).problems ?? null, widths };
}

test("結合のある表は 3 行 3 列で、rowspan と colspan を持つ", async () => {
  const h = (harness = await mount("table-merged"));
  await settle();
  expect(shape(h)).toEqual([
    ["1-1:1×1", "1-2:1×1", "1-3:1×1"],
    ["2-1:1×2", "2-2:1×1", "2-3:1×1"],
    ["3-2:2×1"],
  ]);
});

test("結合が収まる行の入れ替えでは rowspan も colspan も残る", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  moveRow(inner(h), 0, 2);
  await settle();
  expect(shape(h)).toEqual([
    ["2-1:1×2", "2-2:1×1", "2-3:1×1"],
    ["3-2:2×1"],
    ["1-1:1×1", "1-2:1×1", "1-3:1×1"],
  ]);
});

test("列を入れ替えても rowspan も colspan も残る", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  moveColumn(inner(h), 0, 2);
  await settle();
  expect(shape(h)).toEqual([
    ["1-2:1×1", "1-3:1×1", "1-1:1×1"],
    ["2-2:1×1", "2-3:1×1", "2-1:1×2"],
    ["3-2:2×1"],
  ]);
});

test("結合が収まる大きさに広げても結合が残る", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  resizeTable(inner(h), 4, 4);
  await settle();
  expect(shape(h)).toEqual([
    ["1-1:1×1", "1-2:1×1", "1-3:1×1", ":1×1"],
    ["2-1:1×2", "2-2:1×1", "2-3:1×1", ":1×1"],
    ["3-2:2×1", ":1×1"],
    [":1×1", ":1×1", ":1×1", ":1×1"],
  ]);
});

test("横の結合が入り切らない幅に縮めると、その結合だけ 1 マスに割れる", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  resizeTable(inner(h), 3, 2);
  await settle();
  expect(shape(h)).toEqual([
    ["1-1:1×1", "1-2:1×1"],
    ["2-1:1×2", "2-2:1×1"],
    ["3-2:1×1"],
  ]);
});

test("縦の結合が入り切らない高さに縮めると、その結合だけ 1 マスに割れる", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  resizeTable(inner(h), 2, 3);
  await settle();
  expect(shape(h)).toEqual([
    ["1-1:1×1", "1-2:1×1", "1-3:1×1"],
    ["2-1:1×1", "2-2:1×1", "2-3:1×1"],
  ]);
});

test("結合を切る入れ替えでも表の形は壊れない", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  moveRow(inner(h), 1, 2);
  await settle();
  expect(sound(h)).toEqual({ size: "3×3", problems: null, widths: [3, 3, 3] });
});

test("結合を切る入れ替えでは、割れた所が空のセルで埋まる", async () => {
  const h = (harness = await mount("table-merged"));
  caretInCell(h);
  await settle();
  moveRow(inner(h), 1, 2);
  await settle();
  expect(shape(h)).toEqual([
    ["1-1:1×1", "1-2:1×1", "1-3:1×1"],
    [":1×1", "3-2:2×1"],
    ["2-1:1×1", "2-2:1×1", "2-3:1×1"],
  ]);
});

test("結合の無い表の行の入れ替えは今まで通り", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await settle();
  moveRow(inner(h), 0, 1);
  await settle();
  expect(shape(h)).toEqual([
    ["2-1:1×1", "2-2:1×1", "2-3:1×1"],
    ["1-1:1×1", "1-2:1×1", "1-3:1×1"],
  ]);
});

test("結合の無い表の列の入れ替えは今まで通り", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await settle();
  moveColumn(inner(h), 0, 2);
  await settle();
  expect(shape(h)).toEqual([
    ["1-2:1×1", "1-3:1×1", "1-1:1×1"],
    ["2-2:1×1", "2-3:1×1", "2-1:1×1"],
  ]);
});
