// 読めない画像の見せ方。**一覧・カバー画像（Elm の `Ui.thumb` → `asset-thumb`）と
// 本文の画像（`image-node.ts`）が同じ字を出すか。**
//
// 2 つは実装が別（Elm と ProseMirror の node view）なので、同じ画面の中で
// 片方だけブラウザ既定の壊れた画像の印に戻る形が作れてしまう。
import { expect, test, afterEach, vi } from "vitest";
import { mount, type Harness } from "../harness";
import { IMAGE_FAILED } from "../../web/asset-thumb";

let harness: Harness | null = null;
let thumb: HTMLElement | null = null;
afterEach(() => {
  harness?.destroy();
  thumb?.remove();
  thumb = null;
});

// 必ず読み込みに失敗する URL。
const BAD = "/dev/checks/__no-such-image__.png";

function mountThumb(src: string): HTMLElement {
  const created = document.createElement("asset-thumb");
  created.setAttribute("src", src);
  document.body.appendChild(created);
  return (thumb = created);
}

// 断りが出るまで待つ。読み込みの失敗は非同期に来る。
async function noteOf(created: HTMLElement): Promise<HTMLElement> {
  return vi.waitFor(() => {
    const found = created.querySelector<HTMLElement>(".asset-thumb-note")!;
    if (found.hidden) throw new Error("まだ断りが出ていない");
    return found;
  });
}

test("読めない画像は、ブラウザ既定の印ではなく断りの 1 行になる", async () => {
  const created = mountThumb(BAD);
  const note = await noteOf(created);
  expect({ 断り: note.textContent, 画像は隠す: created.querySelector("img")!.hidden }).toEqual({
    断り: IMAGE_FAILED,
    画像は隠す: true,
  });
});

test("断りに asset の id は出さない", async () => {
  const created = mountThumb(BAD);
  const note = await noteOf(created);
  expect(note.textContent).not.toMatch(/[0-9a-f]{8}/);
});

test("本文の画像が読めない時も同じ字を出す", async () => {
  const h = (harness = await mount("image"));
  h.editor.setAttribute("assets", JSON.stringify([{ id: "asset-1", url: BAD }]));
  const note = await vi.waitFor(() => {
    const found = h.editor.querySelector<HTMLElement>(".tt-image-note");
    if (!found || found.hidden) throw new Error("まだ断りが出ていない");
    return found;
  });
  expect(note.textContent).toBe(IMAGE_FAILED);
});
