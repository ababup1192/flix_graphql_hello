// 一覧を上下で選んでいった時、選んでいる行まで面が送られる事。
//
// `place()` は高さを測り直すのに `maxHeight` を一度空にする。その瞬間に面が
// 中身の高さまで伸びて送りが先頭に戻るので、送るのは置き直した後でなければ
// 効かない（言語の候補で、下キーを押しても一覧が付いてこなかった）。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const langBox = (h: Harness) => h.editor.querySelector<HTMLInputElement>(".tt-code-lang")!;
const pop = (h: Harness) => h.editor.querySelector<HTMLElement>(".tt-code-pop")!;

test("言語の候補は下キーで選んだ行まで送られる", async () => {
  const h = (harness = await mount("code"));
  const box = langBox(h);
  await userEvent.click(box);
  // 打って開く。空にすると 88 件すべてが並ぶ。
  await userEvent.keyboard("{Backspace}");
  const face = pop(h);
  expect(face.scrollHeight).toBeGreaterThan(face.clientHeight);
  expect(face.scrollTop).toBe(0);

  for (let step = 0; step < 20; step += 1) await userEvent.keyboard("{ArrowDown}");

  expect(face.scrollTop).toBeGreaterThan(0);
  const at = face.querySelector<HTMLElement>(".is-at")!;
  expect(at.offsetTop).toBeGreaterThanOrEqual(face.scrollTop);
  expect(at.offsetTop + at.offsetHeight).toBeLessThanOrEqual(face.scrollTop + face.clientHeight + 1);
});
