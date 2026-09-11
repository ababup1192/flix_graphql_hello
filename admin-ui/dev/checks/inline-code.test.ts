// 文の中のコード（`` `x` ``）の入力規則が前の 1 文字を巻き込まない事と、
// 箱の右端で打ったバッククォートが箱の中に入らない事。
//
// TipTap の markInputRule は捕まえた前の 1 文字ごと消すので、`a`b`` が `b` だけになっていた。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, lineAt, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const plain = (h: Harness) =>
  (((h.doc() as any).content?.[0]?.content ?? []) as any[]).map((node) => node.text ?? "").join("");

for (const [typed, want] of [
  ["a`b", "a`b"],
  ["a`b`", "ab"],
  ["a *b* c", "a b c"],
  ["a **b** c", "a b c"],
]) {
  test(`「${typed}」と打つと本文が「${want}」になる`, async () => {
    const h = (harness = await mount("empty"));
    await userEvent.keyboard(typed);
    expect(plain(h)).toBe(want);
  });
}

test("バッククォート 1 つではコードにならない", async () => {
  const h = (harness = await mount("empty"));
  await userEvent.keyboard("`code");
  expect(lineAt(h, 0)).toBe("`code[なし]");
});

test("コードの箱の右端で打ったバッククォートは箱の外に残る", async () => {
  const h = (harness = await mount("inline-code"));
  toEnd(h);
  await userEvent.keyboard("`");
  expect(lineAt(h, 0)).toBe("まえ [なし] code[code] `[なし]");
});

test("コードの箱の右端の素の文字は箱を伸ばす", async () => {
  const h = (harness = await mount("inline-code"));
  toEnd(h);
  await userEvent.keyboard("z");
  expect(lineAt(h, 0)).toBe("まえ [なし] codez[code]");
});

test("ボタンでコードにしてから打つと全部が箱に入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  h.apply("code");
  await userEvent.keyboard("abc");
  expect(lineAt(h, 0)).toBe("abc[code]");
});
