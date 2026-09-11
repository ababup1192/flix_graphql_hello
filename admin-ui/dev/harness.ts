// 検査がエディタを立てる所。**開発用の画面と同じ初期状態を使う**（`fixtures.ts`）。
// **開発用の画面と同じ見た目で立てる。** 幅も高さも CSS が決めるので、これが無いと
// 帯や欄が 0 の大きさになり、押す・打つが「見えていない」で落ちる。
import "katex/dist/katex.min.css";
import "../src/styles.css";
import "../web/tiptap-editor";
import { fixtureOf } from "./fixtures";

export type Harness = {
  editor: HTMLElement;
  // 今の doc。属性ではなく `docchange` で出た最後の物を読む（実機と同じ道）。
  doc(): any;
  // doc の中の node の名前を出た順に並べた物。
  names(): string[];
  // 選んでいる所に掛かっているマークの名前。
  marks(): string[];
  // 直前の 1 文字に実際に乗ったマーク。**打った結果を見る**のが本筋で、
  // storedMarks は入力規則が消した後だと空になり、抜けたかどうかが分からない。
  lastMarks(): string[];
  // 文字を選んでツールバーで掛ける道。掛けた直後は storedMarks が立たないので、
  // `exitable` が効かない形（docs/design/editor-dom-parts.md）を再現できる。
  apply(name: string): void;
  // 今打った文字を左へ選ぶ（Shift+← を count 回）。帯の道具は選ばないと押せない。
  selectBack(count: number): void;
  // 選んだ所を右端へ畳む（macOS の ⌘→）。マークは掛かったままで、箱の右端に立つ。
  collapseRight(): void;
  // 画像のキャプションの中にカーソルを置く。メディアの画面を開いた後に
  // 実機がなる形（疑似行が消え、選択が直前の画像のキャプションへ戻る）。
  caretInCaption(): void;
  text(): string;
  destroy(): void;
};

// TipTap の内部。**検査からだけ触る**（画面の実装は `editor` の中に閉じている）。
const inner = (editor: HTMLElement) => (editor as any).editor;

// **1 拍おいてから返す。** カスタム要素は繋がった後に doc を入れ直す道があり、
// その場で選択やマークを触ると後から来た setContent に消される（実際に検査が
// 3 回に 1 回落ちた）。
export async function mount(fixture: string | unknown = "empty"): Promise<Harness> {
  const editor = document.createElement("tiptap-editor");
  // **doc は繋ぐ前に付ける。** 後から付けると、空で組み立てた後に setContent が
  // 走り、その拍子に storedMarks が消えて検査が時々落ちる（実際に 3 回に 1 回落ちた）。
  const doc = typeof fixture === "string" ? fixtureOf(fixture).doc : fixture;
  editor.setAttribute("doc", JSON.stringify(doc));
  document.body.appendChild(editor);
  await new Promise((done) => window.setTimeout(done, 0));
  // **DOM の焦点も自分で当てる。** `commands.focus()` は ProseMirror の選択を
  // 直すだけで、打鍵は document の焦点がある所へ行く。
  const view = inner(editor);
  view?.view?.dom?.focus();
  view?.commands.focus("end");
  return {
    editor,
    doc: () => inner(editor).getJSON(),
    names() {
      const found: string[] = [];
      inner(editor).state.doc.descendants((node: any) => {
        found.push(node.type.name);
      });
      return found;
    },
    marks() {
      const state = inner(editor).state;
      const stored = state.storedMarks ?? state.selection.$from.marks();
      return stored.map((mark: any) => mark.type.name);
    },
    lastMarks() {
      let marks: string[] = [];
      inner(editor).state.doc.descendants((node: any) => {
        if (node.isText) marks = node.marks.map((mark: any) => mark.type.name);
      });
      return marks;
    },
    apply(name: string) {
      inner(editor).chain().focus().toggleMark(name).run();
    },
    // WhyNot: Shift+← と ⌘→ を打鍵で出さない。矢印は 1 つ 1 つが DOM の選択を動かして
    // ProseMirror がそれを読み直す道なので、続けて打つと前のキーの反映を追い越して
    // 選ぶ範囲が 1 文字ずれる（実際に 5 回のうち 2 回ずれた）。**選択の作り方は見る物では
    // ない**ので、結果の選択だけを作る。打つ文字は打鍵のまま。
    selectBack(count: number) {
      const view = inner(editor);
      const at = view.state.selection.to;
      view.commands.setTextSelection({ from: at - count, to: at });
    },
    collapseRight() {
      const view = inner(editor);
      view.commands.setTextSelection(view.state.selection.to);
    },
    caretInCaption() {
      const view = inner(editor);
      let at = -1;
      view.state.doc.descendants((node: any, pos: number) => {
        if (node.type.name === "imageItem" && at < 0) at = pos + 1;
      });
      if (at >= 0) view.commands.setTextSelection(at);
    },
    text: () => inner(editor).state.doc.textContent,
    destroy() {
      editor.remove();
    },
  };
}

// 1 拍おく。**打鍵で動かした選択は、その場では ProseMirror の state に入っていない事がある。**
// 選択を見たり、選択を相手にする道具を使う前に挟む。
export const settle = () => new Promise((done) => window.setTimeout(done, 0));

// 一覧の項目・行番号・掴みは **mousedown で動く**（押した拍子に本文の選択が外れると
// 入れる所が無くなるので、click まで待たずに取る）。押す側もそれに合わせる。
export const press = (el: Element, init: MouseEventInit = {}) =>
  el.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, ...init }));

// 本文の終わりにカーソルを置く。
export function toEnd(harness: Harness) {
  inner(harness.editor).commands.focus("end");
}

// 本文の 1 行を「文字[マーク]」の並びで読む。**打った結果をそのまま並べる**ので、
// 箱が 1 つに繋がったか分かれたかまで出る。
export function lineAt(harness: Harness, index: number): string {
  const nodes = ((harness.doc() as any).content?.[index]?.content ?? []) as any[];
  return nodes
    .map((node) => `${node.text ?? ""}[${(node.marks ?? []).map((mark: any) => mark.type).join("+") || "なし"}]`)
    .join(" ");
}
