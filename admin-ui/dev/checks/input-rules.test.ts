// 入力規則（記法 → 付くマーク）の一覧。
//
// 記号が重なる組（`~` と `~~`、`*` と `**`、`_` と `__`、`=` と `==`、`^` の重なり）で
// 片方が片方を食わない事を 1 枚の表で見る。打つのは行の頭から（TipTap の太字・斜体・
// 打ち消しは前が行頭か空白の時だけ効く）。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 1 行目を「本文 / 付いたマーク」で読む。
function lineOf(h: Harness): { text: string; marks: string } {
  const nodes = ((h.doc() as any).content?.[0]?.content ?? []) as any[];
  return {
    text: nodes.map((node) => node.text ?? "").join(""),
    marks: [...new Set(nodes.flatMap((node) => (node.marks ?? []).map((mark: any) => mark.type)))].join(","),
  };
}

const RULES: Array<[string, string, string]> = [
  ["~~取り消し~~", "取り消し", "strike"],
  ["H~2~O", "H2O", "sub"],
  ["x^2^", "x2", "sup"],
  ["==大事==", "大事", "highlight"],
  ["a`b`", "ab", "code"],
  ["**太字**", "太字", "bold"],
  ["__太字__", "太字", "bold"],
  ["*斜体*", "斜体", "italic"],
  ["_斜体_", "斜体", "italic"],
  ["~~a~~b~c~", "abc", "strike,sub"],
  // 記号 1 つ・記号 3 つ・行の途中の `~~` は何も起きない（打った通りに残る）。
  ["~1つ", "~1つ", ""],
  ["^1つ", "^1つ", ""],
  ["=1つ", "=1つ", ""],
  ["^^x^^", "^^x^^", ""],
  ["~~~x~~~", "~~~x~~~", ""],
  ["前~~消~~後", "前~~消~~後", ""],
];

for (const [typed, text, marks] of RULES) {
  test(`「${typed}」→ 本文「${text}」/ マーク「${marks || "なし"}」`, async () => {
    const h = (harness = await mount("empty"));
    await userEvent.keyboard(typed);
    expect(lineOf(h)).toEqual({ text, marks });
  });
}

// 上付きと下付きは**片方の中にもう片方が無い**（`text-marks.ts` の excludes）。
test("上付きと下付きは重ならない", async () => {
  const h = (harness = await mount("empty"));
  await userEvent.keyboard("a");
  h.selectBack(1);
  h.apply("sup");
  h.apply("sub");
  expect(lineOf(h).marks).toBe("sub");
});
