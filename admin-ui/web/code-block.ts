// コードブロックの見た目と、言語の選び方。
//
// **言語はブロックの上で選ぶ**（GitHub と同じ）。ツールバーに置くと、
// どのブロックの言語を変えているのかが分からず、ブロックが複数あると当たらない。
//
// 言語は 70 以上あるので、**打って絞る**（GitHub の言語の選び方と同じ）。
// セレクトボックスに 70 行並べても読めない。

import type { Editor } from "@tiptap/core";
import { ensure, labelOf, search, type Language } from "./code-languages";
import { dismissOn } from "./dismiss";
import { placeUnder } from "./place";

// 図は**コードブロックの言語を `mermaid` にする**（GitHub / Zenn / esa / Craft と同じ。
// 専用の node を作った例は 1 つも無かった）。CMS も `diagramLanguage()` でこの形を受ける。
const DIAGRAM = "mermaid";

let mermaidReady: Promise<typeof import("mermaid").default> | null = null;

function mermaidOf() {
  if (!mermaidReady) {
    mermaidReady = import("mermaid").then((module) => {
      const dark = document.documentElement.getAttribute("data-theme") === "dark";
      module.default.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict" });
      return module.default;
    });
  }
  return mermaidReady;
}

type Lowlight = Parameters<typeof ensure>[0];

type ViewArgs = {
  node: { type: { name: string }; attrs: Record<string, unknown>; nodeSize: number };
  editor: Editor;
  getPos: () => number | undefined;
};

export function codeBlockView(lowlight: Lowlight) {
  return ({ node, editor, getPos }: ViewArgs) => {
    const dom = document.createElement("div");
    dom.className = "tt-code";

    const bar = document.createElement("div");
    bar.className = "tt-code-bar";

    const button = document.createElement("button");
    button.type = "button";
    button.className = "tt-code-lang";
    bar.appendChild(button);

    const popover = document.createElement("div");
    popover.className = "tt-code-pop";
    popover.hidden = true;
    bar.appendChild(popover);

    const searchBox = document.createElement("input");
    searchBox.className = "tt-code-search";
    searchBox.placeholder = "言語を探す";
    searchBox.setAttribute("aria-label", "言語を探す");
    popover.appendChild(searchBox);

    const list = document.createElement("div");
    list.className = "tt-code-list";
    popover.appendChild(list);

    // ファイル名。CMS は `codeBlock.attrs.fileName` を受け、HTML の pre に data-file-name で出す
    // （microCMS も同じ場所に持つ）。
    const fileName = document.createElement("input");
    fileName.type = "text";
    fileName.className = "tt-code-file";
    fileName.placeholder = "ファイル名";
    fileName.setAttribute("aria-label", "ファイル名");
    bar.appendChild(fileName);

    // 図の描画。**コードの上に置く**（Craft と同じ並び）。図でない時は出さない。
    const figure = document.createElement("div");
    figure.className = "tt-diagram";
    figure.hidden = true;

    const pre = document.createElement("pre");
    const code = document.createElement("code");
    pre.appendChild(code);
    dom.append(bar, figure, pre);

    let drawn = "";
    let drawing = 0;

    // **書いている間ずっと描く。** 壊れた図はそのブロックの中に赤字で出し、
    // 本文の他の所は壊さない。
    const draw = (source: string) => {
      if (current !== DIAGRAM) {
        figure.hidden = true;
        return;
      }
      figure.hidden = false;
      if (source === drawn) return;
      drawn = source;
      // **打っている間は描き直さない。** 1 打鍵ごとに描くと、mermaid の描画が重なって
      // 画面が固まる（実際に固まった）。手が止まってから 1 回だけ描く。
      window.clearTimeout(drawing);
      drawing = window.setTimeout(() => {
        if (!source.trim()) {
          figure.textContent = "";
          return;
        }
        void mermaidOf()
          .then((mermaid) => mermaid.render("tt-mermaid-" + Math.random().toString(36).slice(2), source))
          .then(({ svg }) => {
            if (drawn !== source) return;
            figure.innerHTML = svg;
            figure.classList.remove("is-bad");
          })
          .catch((error: unknown) => {
            if (drawn !== source) return;
            figure.textContent = String(error instanceof Error ? error.message : error).slice(0, 200);
            figure.classList.add("is-bad");
          });
      }, 400);
    };

    let current = typeof node.attrs.language === "string" ? node.attrs.language : "";
    let at = 0;
    let shown: Language[] = [];

    const paintLabel = (attrs?: Record<string, unknown>) => {
      button.textContent = labelOf(current);
      button.classList.toggle("is-unset", current === "");
      const found = typeof attrs?.fileName === "string" ? attrs.fileName : "";
      if (document.activeElement !== fileName) fileName.value = found;
    };

    // **語を打つたびに絞り直す。** 上下で選び、Enter で決める。
    const paintList = () => {
      shown = search(searchBox.value).slice(0, 60);
      at = Math.min(at, Math.max(shown.length - 1, 0));
      list.replaceChildren(
        ...shown.map((language, index) => {
          const row = document.createElement("button");
          row.type = "button";
          row.className = "tt-code-item" + (index === at ? " is-at" : "") + (language.id === current ? " is-on" : "");
          row.textContent = language.label;
          row.addEventListener("mousedown", (event) => {
            event.preventDefault();
            choose(language.id);
          });
          return row;
        })
      );
      const active = list.querySelector<HTMLElement>(".is-at");
      if (active) active.scrollIntoView({ block: "nearest" });
    };

    let undismiss: (() => void) | null = null;

    const open = () => {
      popover.hidden = false;
      searchBox.value = "";
      at = 0;
      paintList();
      placeUnder(popover, button, 240);
      searchBox.focus();
      undismiss = dismissOn({ inside: [popover, button], onClose: () => close() });
    };

    const close = () => {
      undismiss?.();
      undismiss = null;
      popover.hidden = true;
    };

    const choose = async (id: string) => {
      close();
      // **先に文法を読んでから doc を変える。** 逆にすると、色を塗り直す時に
      // まだ文法が無く、色が付かないまま残る。
      await ensure(lowlight, id);
      const pos = getPos();
      if (pos === undefined) return;
      const found = editor.view.state.doc.nodeAt(pos);
      if (!found) return;
      editor.view.dispatch(
        editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, language: id || null })
      );
      editor.commands.focus();
    };

    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      if (popover.hidden) open();
      else close();
    });

    // WhyNot: input の度に書かない。1 文字ごとに doc が変わると undo が 1 文字ずつになる。
    const writeFileName = () => {
      const pos = getPos();
      if (pos === undefined) return;
      const found = editor.view.state.doc.nodeAt(pos);
      if (!found) return;
      const typed = fileName.value.trim();
      // CMS が受けるのは `RichText.isFileName` の形。受けない物は入れない。
      const value = typed !== "" && /^[\p{L}\p{N}_./-]{1,200}$/u.test(typed) ? typed : null;
      fileName.classList.toggle("is-bad", typed !== "" && value === null);
      if (value === (found.attrs.fileName ?? null)) return;
      editor.view.dispatch(editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, fileName: value }));
    };
    fileName.addEventListener("blur", writeFileName);
    fileName.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      fileName.blur();
    });

    searchBox.addEventListener("input", () => {
      at = 0;
      paintList();
    });

    searchBox.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        at = Math.min(at + 1, shown.length - 1);
        paintList();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        at = Math.max(at - 1, 0);
        paintList();
      } else if (event.key === "Enter") {
        event.preventDefault();
        const picked = shown[at];
        if (picked) void choose(picked.id);
      } else if (event.key === "Escape") {
        event.preventDefault();
        close();
        editor.commands.focus();
      }
    });

    searchBox.addEventListener("blur", () => {
      // 選んだ物を押す前に閉じないよう、少し待つ。
      window.setTimeout(close, 120);
    });

    paintLabel(node.attrs);
    draw((node as unknown as { textContent: string }).textContent ?? "");

    return {
      dom,
      contentDOM: code,
      update(updated: { type: { name: string }; attrs: Record<string, unknown>; textContent: string }) {
        if (updated.type.name !== "codeBlock") return false;
        current = typeof updated.attrs.language === "string" ? updated.attrs.language : "";
        paintLabel(updated.attrs);
        draw(updated.textContent);
        return true;
      },
      // **ProseMirror の中身は `pre` の中だけ。** 上の帯と図はこちらが描く物なので、
      // 触っても doc は動かさない。図を描いた時に doc が動くと、描く → 更新 → また描く、
      // の輪になって図が出ない（実際になった）。
      ignoreMutation(mutation: { target: Node }) {
        return !pre.contains(mutation.target);
      },
      stopEvent(event: Event) {
        return bar.contains(event.target as Node);
      },
      destroy() {
        close();
      },
    };
  };
}

// doc の中で使われている言語を全部読む。**開いた時に色が付いている**ようにする。
export function ensureUsed(lowlight: Lowlight, doc: unknown): Promise<void[]> {
  const found = new Set<string>();
  const walk = (node: unknown) => {
    if (!node || typeof node !== "object") return;
    const record = node as { type?: string; attrs?: { language?: unknown }; content?: unknown[] };
    if (record.type === "codeBlock" && typeof record.attrs?.language === "string") found.add(record.attrs.language);
    for (const child of record.content ?? []) walk(child);
  };
  walk(doc);
  return Promise.all([...found].map((id) => ensure(lowlight, id)));
}
