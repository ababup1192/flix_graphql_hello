// コードブロックの見た目と、言語の選び方。
//
// **言語はブロックの下の帯で選ぶ**（note と同じ。`docs/design/richtext-note-codeblock-ui.md`）。
// ツールバーに置くと、どのブロックの言語を変えているのかが分からず、ブロックが複数あると当たらない。
//
// 言語は 70 以上あるので、**打って絞る**。セレクトボックスに 70 行並べても読めない。

import type { Editor } from "@tiptap/core";
import { dropPendingLine, leaveBlock } from "./block-edges";
import { ensure, extensionOf, labelOf, markOf, search, type Option } from "./code-languages";
import { bar as barOf, field, owns, popover } from "./ui";

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

// `1,3-5` を行番号の集まりに開く。CMS の `RichText.isHighlightLines` が受ける形しか読まない。
function readLines(value: unknown): Set<number> {
  const out = new Set<number>();
  if (typeof value !== "string") return out;
  for (const part of value.split(",")) {
    const [from, to] = part.split("-").map((piece) => Number.parseInt(piece, 10));
    if (!Number.isInteger(from) || from < 1) continue;
    const last = Number.isInteger(to) && to >= from ? to : from;
    for (let line = from; line <= Math.min(last, from + 9999); line += 1) out.add(line);
  }
  return out;
}

// 行番号の集まりを `1,3-5` に畳む。**続きの行は範囲にする**（1,2,3 が 3 つ並ぶと読めない）。
function writeRanges(lines: Set<number>): string | null {
  const sorted = [...lines].sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const parts: string[] = [];
  let from = sorted[0];
  let last = sorted[0];
  for (const line of sorted.slice(1)) {
    if (line === last + 1) {
      last = line;
      continue;
    }
    parts.push(from === last ? `${from}` : `${from}-${last}`);
    from = line;
    last = line;
  }
  parts.push(from === last ? `${from}` : `${from}-${last}`);
  return parts.join(",");
}

export function codeBlockView(lowlight: Lowlight) {
  return ({ node, editor, getPos }: ViewArgs) => {
    const dom = document.createElement("div");
    dom.className = "tt-code";

    // ファイル名。CMS は `codeBlock.attrs.fileName` を受け、HTML の pre に data-file-name で出す
    // （microCMS も同じ場所に持つ）。
    const fileName = field({
      className: "tt-code-file",
      placeholder: "ファイル名",
      onCommit: () => writeFileName(),
      onLeave: (dir) => leaveCode(dir),
      onDown: () => dropPendingLine(editor.view),
    });

    // 言語。**決めた後の表示と、打って絞る入力を同じ欄が兼ねる**（note と同じ）。
    // 別の欄にすると、帯の右端に読む所と打つ所が 2 つ並ぶ。
    //
    // WhyNot: `onCommit` / `onLeave` を渡さない。この欄の Enter と上下は候補を選ぶ物なので、
    // 部品の既定（Enter で確定・端で外へ出る）に取られると候補が決められない。
    const langBox = field({
      className: "tt-code-lang",
      placeholder: "コーディング言語",
      onDown: () => dropPendingLine(editor.view),
    });

    // ブロックの**下**の帯。左からファイル名・強調行・言語。
    const bar = barOf({ className: "tt-code-bar", children: [fileName, langBox] });

    // 候補の一覧は**帯の子**として絶対位置で置く（`ui.ts` の popover が親基準で置く）。
    const pop = popover({
      anchor: bar,
      place: { side: "below", align: "end" },
      className: "tt-code-pop",
      keep: [langBox],
      bounds: editor.view.dom,
    });

    const list = document.createElement("div");
    list.className = "tt-code-list";
    pop.dom.appendChild(list);

    // 図の描画。**コードの上に置く**（Craft と同じ並び）。図でない時は出さない。
    const figure = document.createElement("div");
    figure.className = "tt-diagram";
    figure.hidden = true;

    // 行番号と強調の帯。**行は要素になっていない**（contenteditable の中の 1 続きの文字）ので、
    // 改行の数から番号を作り、地の帯は行の高さの倍数で置く。
    //
    // WhyNot: 折り返さない（`white-space: pre` で横に送る）。折り返すと 1 行が 2 行分の高さに
    // なり、番号と実際の行がずれる。ずれない形にするには行ごとに要素が要るが、それは
    // ProseMirror が持つ中身の作りを変える事になる。
    const main = document.createElement("div");
    main.className = "tt-code-main";

    const gutter = document.createElement("div");
    gutter.className = "tt-code-gutter";
    gutter.contentEditable = "false";

    const bands = document.createElement("div");
    bands.className = "tt-code-bands";
    bands.contentEditable = "false";

    const pre = document.createElement("pre");
    const code = document.createElement("code");
    pre.appendChild(code);
    main.append(bands, gutter, pre);
    dom.append(figure, main, bar);

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
    let text = (node as unknown as { textContent: string }).textContent ?? "";
    let at = 0;
    let shown: Option[] = [];

    // 焦点がこのブロックから離れている間は、帯だけを残して placeholder を消す（note と同じ）。
    const paintIdle = () => {
      const pos = getPos();
      const found = pos === undefined ? null : editor.view.state.doc.nodeAt(pos);
      const cursor = editor.view.state.selection.from;
      const inCode =
        editor.view.hasFocus() && found !== null && pos !== undefined && cursor > pos && cursor < pos + found.nodeSize;
      const inside = dom.contains(document.activeElement) || inCode;
      dom.classList.toggle("is-idle", !inside);
    };

    const paintLabel = (attrs?: Record<string, unknown>) => {
      // 言語ごとに配色を足せるようにする（差分の `@@` の行など）。
      // WhyNot: `code` に `language-*` の class を付けない。中身は ProseMirror が持つ DOM で、
      // こちらが足した class は描き直しで消える。外側の箱に持たせる。
      dom.dataset.language = current;
      // 打っている間は上書きしない（絞り込みの文字が消える）。
      if (document.activeElement !== langBox) langBox.value = labelOf(current);
      const file = typeof attrs?.fileName === "string" ? attrs.fileName : "";
      if (document.activeElement !== fileName) fileName.value = file;
      paintIdle();
    };

    // 強調行。doc に入るのは `1,3-5` の 1 本の文字列で、画面では行番号の押した / 押していないで持つ。
    let marked = readLines(node.attrs.highlightLines);
    let anchor = 0;

    const writeLines = () => {
      const pos = getPos();
      if (pos === undefined) return;
      const found = editor.view.state.doc.nodeAt(pos);
      if (!found) return;
      const value = writeRanges(marked);
      if (value === (found.attrs.highlightLines ?? null)) return;
      editor.view.dispatch(
        editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, highlightLines: value })
      );
    };

    // 行番号と、強調した行の地の帯を引き直す。
    const paintGutter = (text: string) => {
      const count = Math.max(text.split("\n").length, 1);
      gutter.replaceChildren(
        ...Array.from({ length: count }, (_ignore, index) => {
          const line = index + 1;
          const row = document.createElement("button");
          row.type = "button";
          row.className = "tt-code-line" + (marked.has(line) ? " is-on" : "");
          row.textContent = String(line);
          row.title = "この行を強調";
          row.setAttribute("aria-pressed", String(marked.has(line)));
          row.addEventListener("mousedown", (event) => {
            event.preventDefault();
            pick(line, event.shiftKey);
          });
          return row;
        })
      );
      bands.replaceChildren(
        ...[...marked]
          .filter((line) => line <= count)
          .map((line) => {
            const band = document.createElement("div");
            band.className = "tt-code-band";
            band.style.top = `calc(var(--tt-code-pad) + ${line - 1} * var(--tt-code-line))`;
            return band;
          })
      );
    };

    // 押すと強調、もう一度押すと解除。Shift は前に押した行からの範囲。
    const pick = (line: number, ranged: boolean) => {
      if (ranged && anchor > 0) {
        const [from, to] = anchor <= line ? [anchor, line] : [line, anchor];
        for (let step = from; step <= to; step += 1) marked.add(step);
      } else if (marked.has(line)) {
        marked.delete(line);
        anchor = 0;
      } else {
        marked.add(line);
        anchor = line;
      }
      paintGutter(text);
      writeLines();
    };

    // **語を打つたびに絞り直す。** 上下で選び、Enter で決める。
    const paintList = () => {
      shown = search(langBox.value).slice(0, 60);
      at = Math.min(at, Math.max(shown.length - 1, 0));
      list.replaceChildren(
        ...shown.map((option, index) => {
          const row = document.createElement("button");
          row.type = "button";
          row.className = "tt-code-item" + (index === at ? " is-at" : "") + (option.id === current ? " is-on" : "");
          const mark = markOf(option);
          const badge = document.createElement("span");
          badge.className = `tt-code-mark is-tone-${mark.tone}`;
          badge.textContent = mark.text;
          const name = document.createElement("span");
          name.className = "tt-code-name";
          name.textContent = option.id;
          row.append(badge, name);
          // 別名は正式名の右に薄く添える（別の行にすると、どちらが正式名か分からない）。
          if (option.aliases.length > 0) {
            const alias = document.createElement("span");
            alias.className = "tt-code-alias";
            alias.textContent = option.aliases.join(", ");
            row.appendChild(alias);
          }
          row.addEventListener("mousedown", (event) => {
            event.preventDefault();
            void choose(option.id);
          });
          return row;
        })
      );
      const active = list.querySelector<HTMLElement>(".is-at");
      if (active) active.scrollIntoView({ block: "nearest" });
      // 候補の数で面の高さが変わるので、置き直す（下に入らなければ上へ返る）。
      pop.place();
    };

    const open = () => {
      at = 0;
      pop.open(langBox);
      paintList();
    };

    const close = () => pop.close();

    // `andFocus` は、選んだ後に本文へ焦点を戻すか。ファイル名から埋める時は戻さない
    // （ファイル名の欄を離れただけなのに、本文にカーソルが飛ぶ）。
    const choose = async (id: string, andFocus = true) => {
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
      current = id;
      langBox.value = labelOf(id);
      if (andFocus) editor.commands.focus();
    };

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
      if (value !== null) guessLanguage(value);
    };

    // ファイル名の拡張子から言語を埋める（`test.flix` で Flix）。
    //
    // WhyNot: 既に言語が入っている時は上書きしない。手で選んだ後にファイル名を直しただけで
    // 言語が変わると驚く。埋めるのは空の時だけ。
    const guessLanguage = (value: string) => {
      if (current !== "") return;
      const guessed = extensionOf(value);
      if (guessed === "") return;
      void choose(guessed, false);
    };

    // 帯の欄から前後の行へ出る（`ui.ts` の field の `onLeave` が呼ぶ）。
    const leaveCode = (dir: -1 | 1) => {
      const pos = getPos();
      if (pos === undefined) return;
      const found = editor.view.state.doc.nodeAt(pos);
      if (!found) return;
      leaveBlock(editor.view, pos, found.nodeSize, dir);
    };

    // 言語の欄。入ると整った名前を外して素の名前で絞れるようにし、離れると整った名前へ戻す。
    langBox.addEventListener("focus", () => {
      langBox.value = "";
      open();
    });

    langBox.addEventListener("input", () => {
      at = 0;
      if (!pop.isOpen) open();
      else paintList();
    });

    langBox.addEventListener("keydown", (event) => {
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

    langBox.addEventListener("blur", () => {
      // 選んだ物を押す前に閉じないよう、少し待つ。
      window.setTimeout(() => {
        close();
        langBox.value = labelOf(current);
        paintIdle();
      }, 120);
    });

    // 帯の中の欄と本文の行き来で、帯の出し方（placeholder の有無）が変わる。
    dom.addEventListener("focusin", paintIdle);
    dom.addEventListener("focusout", () => window.setTimeout(paintIdle, 0));
    editor.on("selectionUpdate", paintIdle);
    editor.on("blur", paintIdle);

    paintLabel(node.attrs);
    paintGutter(text);
    draw(text);

    return {
      dom,
      contentDOM: code,
      update(updated: { type: { name: string }; attrs: Record<string, unknown>; textContent: string }) {
        if (updated.type.name !== "codeBlock") return false;
        current = typeof updated.attrs.language === "string" ? updated.attrs.language : "";
        text = updated.textContent;
        marked = readLines(updated.attrs.highlightLines);
        paintLabel(updated.attrs);
        paintGutter(text);
        draw(text);
        return true;
      },
      // **ProseMirror の中身は `pre` の中だけ。** 下の帯と図はこちらが描く物なので、
      // 触っても doc は動かさない。図を描いた時に doc が動くと、描く → 更新 → また描く、
      // の輪になって図が出ない（実際になった）。
      ignoreMutation(mutation: { target: Node }) {
        return !pre.contains(mutation.target);
      },
      stopEvent(event: Event) {
        return owns([bar, pop.dom, gutter], event);
      },
      destroy() {
        pop.destroy();
        editor.off("selectionUpdate", paintIdle);
        editor.off("blur", paintIdle);
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
