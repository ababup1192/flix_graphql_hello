// 日本語入力（IME）。**未確定（変換中）の状態を本物のブラウザに作らせて**、
// その間にエディタが余計な事をしないか、確定した文字が消えないかを見る。
//
// 未確定は Chrome DevTools Protocol の `Input.imeSetComposition` で作る。ブラウザが本物の
// `compositionstart` / `compositionupdate` / `compositionend` を出すので、ProseMirror も
// 実機と同じ道（`view.composing` が立ち、DOM の変更を後で読み直す）を通る。
//
// WhyNot: `userEvent.keyboard("日本")` で代わりにしない。打鍵は確定した文字を 1 つずつ入れる
// だけで、**未確定の状態がそもそも存在しない**ので、見たい道を 1 つも通らない。
//
// 確かめていない事: macOS のかな入力・ライブ変換・ことえりの癖、Windows / Android の IME の
// 差。CDP が出すのは W3C の composition イベントの並びだけで、OS ごとの癖は再現できない。
import { expect, test, afterEach, vi } from "vitest";
import { cdp } from "vitest/browser";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const inner = (h: Harness) => (h.editor as any).editor;

// WhyNot: `cdp()` の戻りをそのまま呼ばない。この版の `CDPSession` は中身の無い interface
// （`vitest/dist/browser.d.ts` の `interface CDPSession {}`）で、`send` が型に載っておらず
// `tsc --noEmit` が落ちる。
type Cdp = { send(method: string, params: Record<string, unknown>): Promise<unknown> };
const send = (method: string, params: Record<string, unknown>) => (cdp() as unknown as Cdp).send(method, params);

/** 未確定の文字を置く（変換中）。カーソルは末尾。 */
const compose = async (text: string) => {
  await send("Input.imeSetComposition", { text, selectionStart: text.length, selectionEnd: text.length });
  await settle();
};

/** 変換を確定する。 */
const commit = async (text: string) => {
  await send("Input.insertText", { text });
  await settle();
};

/** 変換を取り消す（未確定を捨てる）。 */
const cancel = async () => {
  await send("Input.imeSetComposition", { text: "", selectionStart: 0, selectionEnd: 0 });
  await settle();
};

/** 未確定の間にキーを送る（IME が食う前提のキー）。 */
const keyWhileComposing = async (key: string, code: string) => {
  for (const type of ["rawKeyDown", "keyUp"] as const) {
    await send("Input.dispatchKeyEvent", { type, key, code, windowsVirtualKeyCode: key === "Enter" ? 13 : 27 });
  }
  await settle();
};

/** 名前の node の中の文字。**本文全体ではなく中身を見る**（別の所に入ったのを見逃さない）。 */
function textIn(h: Harness, name: string): string {
  let found = "";
  inner(h).state.doc.descendants((node: any) => {
    if (node.type.name === name && found === "") found = node.textContent;
  });
  return found;
}

/** カーソルを名前の node の中に置く。 */
async function caretIn(h: Harness, name: string) {
  const view = inner(h);
  let at = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && at < 0) at = pos + 1;
  });
  view.commands.focus();
  view.commands.setTextSelection(at);
  view.view.dom.focus();
  await settle();
}

// ---- 1. CDP が本当に効いているか ----

// これが落ちたら以下の検査は全部意味を失うので、最初に置く。
test("未確定の間は view.composing が立ち、確定すると文字が入る", async () => {
  const h = (harness = await mount("empty"));
  const view = inner(h);
  const seen: string[] = [];
  for (const name of ["compositionstart", "compositionupdate", "compositionend"]) {
    view.view.dom.addEventListener(name, () => seen.push(name));
  }
  await compose("にほん");
  const composing = view.view.composing;
  const midText = h.text();
  await commit("日本");
  expect({ composing, midText, text: h.text(), start: seen[0], end: seen[seen.length - 1] }).toEqual({
    composing: true,
    midText: "にほん",
    text: "日本",
    start: "compositionstart",
    end: "compositionend",
  });
});

// ---- 2. node view の中で変換する ----

// node view の `stopEvent` / `ignoreMutation` が未確定の DOM の変更を捨てると、
// 確定した文字がそのまま消える。**中に文字が入る所すべて**で見る。
// [名前, 初期状態, カーソルを置く node]
const INSIDE: Array<[string, string, string]> = [
  ["画像のキャプション", "image", "imageItem"],
  ["引用の出典", "quote", "quoteCite"],
  ["表のセル", "table", "tableCell"],
  ["コードブロック", "code", "codeBlock"],
];

for (const [name, fixture, node] of INSIDE) {
  test(`${name}の中で変換して確定した文字が残る`, async () => {
    const h = (harness = await mount(fixture));
    await caretIn(h, node);
    await compose("にほんご");
    const mid = textIn(h, node).includes("にほんご");
    await commit("日本語");
    expect({ mid, text: textIn(h, node).includes("日本語") }).toEqual({ mid: true, text: true });
  });
}

// ---- 3. 変換中に入力規則が走らない ----

// 未確定の記法はまだ文字ではないので、見出し・太字・引用に化けてはいけない。
// [打つ未確定, 出てはいけない node / マーク]
const NO_RULE: Array<[string, string]> = [
  ["# ", "heading"],
  ["> ", "blockquote"],
  ["- ", "bulletList"],
  ["```", "codeBlock"],
];

for (const [typed, node] of NO_RULE) {
  test(`変換中の「${typed}」が ${node} にならない`, async () => {
    const h = (harness = await mount("empty"));
    await compose(typed);
    expect(h.names()).not.toContain(node);
  });
}

test("変換中の ** が太字にならない", async () => {
  const h = (harness = await mount("empty"));
  await compose("**ふとじ**");
  expect({ marks: h.lastMarks(), text: h.text() }).toEqual({ marks: [], text: "**ふとじ**" });
});

// 確定した後は規則が効く（変換中に止めるのが目的で、規則を殺すのではない）。
test("確定した「# 」は見出しになる", async () => {
  const h = (harness = await mount("empty"));
  await compose("#");
  await commit("# ");
  expect(h.names()).toContain("heading");
});

// ---- 4. 変換中の Enter ----

// IME の確定であって、段落を割ったりリストを増やしたりしない。
test("変換中の Enter が段落を割らない", async () => {
  const h = (harness = await mount("empty"));
  await compose("にほん");
  const before = h.names().filter((name) => name === "paragraph").length;
  await keyWhileComposing("Enter", "Enter");
  expect(h.names().filter((name) => name === "paragraph").length).toBe(before);
});

test("変換中の Enter がリストの項目を増やさない", async () => {
  const h = (harness = await mount("empty"));
  await commit("- ");
  await compose("こうもく");
  const before = h.names().filter((name) => name === "listItem").length;
  await keyWhileComposing("Enter", "Enter");
  expect(h.names().filter((name) => name === "listItem").length).toBe(before);
});

// ---- 5. 変換中にバブルメニューが出ない ----

// 未確定の範囲は「選んだ」ではない。帯が出ると変換中の文字に被る。
test("変換中にバブルメニューが出ない", async () => {
  const h = (harness = await mount("empty"));
  await compose("にほんご");
  // 帯は updateDelay 80ms で出るので、出る時間を与えてから見る。
  await new Promise((done) => window.setTimeout(done, 200));
  expect(h.editor.querySelector(".tt-bubble")).toBeNull();
});

// 選んだ文字を変換で置き換える道。**帯が出ている所から変換に入る**ので、
// 「出さない」ではなく「引っ込む」を見る（未確定の間も帯が残ると文字に被る）。
//
// **今は残ってしまう**（2026-09-12 の実測: 未確定の 200ms 後も `.tt-bubble` が
// `opacity: 1` で居た。同じ手順を変換ではなく素の打鍵で置き換えると引っ込む＝IME の側だけ）。
// 直りしだい `test.fails` を `test` に戻す。
test.fails("選んだ文字を変換で置き換えるとバブルメニューが引っ込む", async () => {
  const h = (harness = await mount("empty"));
  await commit("えらぶ");
  h.selectBack(3);
  await settle();
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-bubble")).not.toBeNull());
  await compose("にほんご");
  await new Promise((done) => window.setTimeout(done, 200));
  expect(h.editor.querySelector(".tt-bubble")).toBeNull();
});

// 確定して選べば出る（帯を殺すのではない）。
test("確定した文字を選べばバブルメニューが出る", async () => {
  const h = (harness = await mount("empty"));
  await compose("にほんご");
  await commit("日本語");
  h.selectBack(3);
  await settle();
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-bubble")).not.toBeNull());
  expect(h.editor.querySelector(".tt-bubble")).not.toBeNull();
});

// ---- 6. docchange ----

// 変換中に「未保存」が立つと、打ち終える前に下書きの保存が走り、**未確定の文字が下書きに入る**。
//
// **今は出てしまう**（2026-09-12 の実測: 「にほん」の未確定で docchange が 1 回、detail の
// doc に「にほん」が入っていた）。直りしだい `test.fails` を `test` に戻す。
// WhyNot: 期待の側を「出る」に書き換えない。書き換えると直した時に誰も気付かない。
test.fails("変換中は docchange が出ない", async () => {
  const h = (harness = await mount("text"));
  const beats: string[] = [];
  h.editor.addEventListener("docchange", (event) => beats.push((event as CustomEvent).detail));
  await compose("にほん");
  const mid = beats.length;
  await commit("日本");
  expect({ mid, after: beats.length > 0 }).toEqual({ mid: 0, after: true });
});

// ---- 7. 変換の取り消しと ⌘Z ----

test("変換中に取り消すと未確定の文字が残らない", async () => {
  const h = (harness = await mount("empty"));
  await compose("にほん");
  await cancel();
  expect(h.text()).toBe("");
});

// 確定した分は 1 回の取り消しで丸ごと戻る（1 文字ずつ戻らない）。
//
// WhyNot: 前の入力の直後に変換しない。ProseMirror の履歴は時間で 1 つの塊にまとめる
// （`newGroupDelay` 500ms）ので、続けて打つと前の入力まで一緒に戻り、IME のせいに見える。
test("確定した後の取り消し 1 回で確定分が戻る", async () => {
  const h = (harness = await mount("empty"));
  await commit("まえ");
  await new Promise((done) => window.setTimeout(done, 600));
  await compose("にほん");
  await commit("日本語");
  inner(h).commands.undo();
  await settle();
  expect(h.text()).toBe("まえ");
});
