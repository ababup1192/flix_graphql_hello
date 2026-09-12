// 本文の画像。1 枚でも複数枚でも `image` 1 つで、中に `imageItem` を並べる。
//
// 帯と列の決めは `docs/design/richtext-gallery-ui.md`（見た目は `richtext-gallery-mock.html`）。
// **列は人に選ばせず枚数から決まる**。並べている間の帯は 1 枚ずつに戻す / 削除。
//
// WhyNot: `gallery` の node を持たない。別 node だと「並べる / 1 枚ずつ」が node の作り直しになり、
// 選択とキャプションが毎回飛ぶ。子の出し入れだけで済む形にする（`richtext-gallery-ui.md` 1）。
// 読む側だけは旧 `gallery` と旧 `image`（attrs.assetId）を `liftImageItems` で写す。
//
// WhyNot: 全体のキャプション（並べた画像の下に 1 つ）を置かない。キャプションは画像ごとの 1 層だけ
// （`docs/design/richtext-gallery-ui.md` 4）。
//
// CMS の `imageItem` は `assetId` を持つ node で、`src` は持たない
// （`src/cms/rules/RichText.flix`）。URL は asset の id から画面では引けないので、
// **Elm が `assets` の属性で id → URL の対応を渡す**。
//
// キャプションは node の中身（text と marks）で、attrs には持たない。
//
// WhyNot: `@tiptap/extension-image` を使わない。あれは `src` を属性に持つ node で、
// 保存すると CMS が断る。属性を差し替えるより、`assetId` の node を自分で持つ方が
// 「保存できる形」と「画面に出る形」が 1 か所で揃う。
//
// WhyNot: キャプションを文字列の attr にしない。note はキャプションにリンクを書く文化で、
// attr だと link / bold のような mark を掛ける場所が無い。
//
// WhyNot: 画像を上げる所でも API を叩かない。エディタは URL もヘッダも知らない
// （`linkopen` と同じ決まり）。ファイルは `mediaupload` の event で外に出す。

import { Node, Extension } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { leaveBlock } from "./block-edges";
import { isHttpUrl } from "./note-input";
import { ICONS, svg } from "./icons";
import { bar as barOf, iconButton } from "./ui";

export type AssetInfo = { id: string; url: string; alt?: string };

// 並べた時の列。**人に選ばせず枚数から決める**（`docs/design/richtext-gallery-ui.md` 2）。
// 4 枚以上は 3 列で折り返す。
//
// WhyNot: 横スクロールにしない。読み手が続きに気づかない。編集画面は折り返して全部見せ、
// 横に送るかは公開側の CSS が決める。
const MAX_COLUMNS = 3;
const columnsFor = (count: number) => (count <= 1 ? 1 : Math.min(count, MAX_COLUMNS));

/** id → URL の対応。Elm から属性で来て、変わったら描き直す。 */
export class AssetStore {
  private map = new Map<string, AssetInfo>();
  private listeners = new Set<() => void>();

  set(list: AssetInfo[]) {
    this.map = new Map(list.filter((asset) => asset && asset.id).map((asset) => [asset.id, asset]));
    for (const listener of this.listeners) listener();
  }

  get(id: string | null | undefined): AssetInfo | undefined {
    return id ? this.map.get(id) : undefined;
  }

  watch(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

type ViewArgs = {
  node: any;
  getPos: () => number | undefined;
  editor: any;
  view: any;
};

// CMS が受ける値（`RichText.checkImage`）。size は "small" だけ。
const SMALL = "small";
// 配置。中央は null（既定）。
const ALIGNS: Array<{ value: string | null; icon: string; title: string }> = [
  { value: "left", icon: ICONS.alignLeft, title: "左に寄せる" },
  { value: null, icon: ICONS.alignCenter, title: "中央に寄せる" },
  { value: "right", icon: ICONS.alignRight, title: "右に寄せる" },
];
// 帯のアイコンの大きさ。ツールバー（16px）より大きい（帯のボタンが 36px）。
const BAR_ICON = 22;

// 帯の中身。tools（リンク / ALT / …）、align（3 つの寄せ）、入力（alt / href / source）のどれか 1 つ。
type BarMode = "tools" | "align" | "alt" | "href" | "source";

// 帯が tools 以外になっている node view の「戻す」。Esc（エディタに焦点がある時）で呼ぶ。
const openBars = new Set<() => boolean>();

/** 選択が画像のキャプションの中にあるか（キャプションの文字を選んでいる時も含む）。 */
export function insideImage(state: any): boolean {
  const $from = state.selection.$from;
  if (state.selection instanceof NodeSelection) return false;
  for (let depth = $from.depth; depth > 0; depth -= 1) if ($from.node(depth).type.name === "imageItem") return true;
  return false;
}

// 知らない id が来ても壊さない。**枠だけ出す**（読み込みの途中と、消された asset の両方がある）。
//
// WhyNot: width / height が attrs に無い時も `<img>` を素で置かない。URL が引けた直後は
// 読み込みが終わるまで 0×0 で、選んでいると outline の輪だけが見える。読み込み中は
// `is-loading` の枡を出し、失敗は `is-unknown` に落とす（`onerror` は src を変えた時に限る。
// Elm が同じ URL を渡し直しても失敗が消えない）。
function paintImage(box: HTMLElement, img: HTMLImageElement, note: HTMLElement, store: AssetStore, attrs: Record<string, unknown>) {
  const assetId = typeof attrs.assetId === "string" ? attrs.assetId : "";
  const found = store.get(assetId);
  const alt = typeof attrs.alt === "string" ? attrs.alt : found?.alt ?? "";
  const unknown = (text: string) => {
    img.hidden = true;
    note.hidden = false;
    note.textContent = text;
    box.classList.add("is-unknown");
    box.classList.remove("is-loading");
  };
  if (!found) {
    img.removeAttribute("src");
    unknown(assetId ? assetId : "（メディアが選ばれていません）");
    return;
  }
  const size = (name: string) => (typeof attrs[name] === "number" && (attrs[name] as number) > 0 ? String(attrs[name]) : null);
  const width = size("width");
  const height = size("height");
  if (width && height) {
    img.setAttribute("width", width);
    img.setAttribute("height", height);
  } else {
    img.removeAttribute("width");
    img.removeAttribute("height");
  }
  img.alt = alt;
  const failed = `${assetId} 読み込めませんでした`;
  if (img.dataset.failed === found.url) {
    unknown(failed);
    return;
  }
  if (img.getAttribute("src") !== found.url) {
    box.classList.toggle("is-loading", !(width && height));
    img.onload = () => box.classList.remove("is-loading");
    img.onerror = () => {
      img.dataset.failed = found.url;
      unknown(failed);
    };
    img.src = found.url;
  }
  img.hidden = false;
  note.hidden = true;
  box.classList.remove("is-unknown");
}

// 帯に入る 1 行の欄。書くのは 適用 / Enter の時だけで、blur では書かない（× と Esc は捨てる）。
function barInput(placeholder: string, className: string, url: boolean): HTMLInputElement {
  const input = document.createElement("input");
  input.type = "text";
  input.className = `tt-image-field ${className}`;
  input.placeholder = placeholder;
  input.setAttribute("aria-label", placeholder);
  if (url) {
    input.inputMode = "url";
    const mark = () => input.classList.toggle("is-bad", !isHttpUrl(input.value.trim()));
    input.addEventListener("input", mark);
  }
  return input;
}

/** 画像 1 枚。attrs を持ち、中身はその 1 枚のキャプション。 */
export function imageItemNode(store: AssetStore) {
  return Node.create({
    name: "imageItem",
    // WhyNot: `inline*` にしない。hardBreak が入り、キャプションが 2 行になる（1 行の決まり）。
    content: "text*",
    marks: "link bold italic strike code",
    draggable: true,
    isolating: true,

    addAttributes() {
      return {
        assetId: { default: null },
        alt: { default: null },
        source: { default: null },
        sourceUrl: { default: null },
        width: { default: null },
        height: { default: null },
        href: { default: null },
        size: { default: null },
        align: { default: null },
      };
    },

    parseHTML() {
      return [{ tag: "figure[data-asset-id]", contentElement: "figcaption" }, { tag: "img[data-asset-id]" }];
    },

    renderHTML({ HTMLAttributes }) {
      return ["figure", { "data-asset-id": String(HTMLAttributes.assetId ?? "") }, ["figcaption", 0]];
    },

    addKeyboardShortcuts() {
      const inCaption = () => insideImage(this.editor.state);
      const swallow = () => inCaption();
      // 上下の矢印でキャプションから画像の外の段落へ。
      const leave = (dir: -1 | 1) => () => {
        const state = this.editor.state;
        if (!inCaption()) return false;
        const $from = state.selection.$from;
        const pos = $from.before($from.depth);
        return leaveBlock(this.editor.view, pos, $from.node($from.depth).nodeSize, dir);
      };
      // 末尾で Delete を素の動きに任せると、隣の段落と結合して画像が消える。
      //
      // WhyNot: Backspace は書かない。先頭の Backspace は blockEdges が先に受けていて、
      // ここに書いても一度も呼ばれない（2026-09-12 に外して振る舞いが変わらない事を見た）。
      const atEnd = () => {
        const state = this.editor.state;
        if (!inCaption() || !state.selection.empty) return false;
        const $from = state.selection.$from;
        return $from.parentOffset === $from.parent.content.size;
      };
      return {
        Enter: swallow,
        "Shift-Enter": swallow,
        "Mod-Enter": swallow,
        ArrowUp: leave(-1),
        ArrowDown: leave(1),
        Delete: atEnd,
        // 配置の 3 つに入れ替わった帯を元に戻す（入力の欄の Esc は欄が自分で受ける）。
        Escape: () => {
          let handled = false;
          for (const back of openBars) if (back()) handled = true;
          return handled;
        },
      };
    },

    addProseMirrorPlugins() {
      return [
        new Plugin({
          key: new PluginKey("imageClick"),
          props: {
            // キャプションの外（画像そのもの）を押したら node ごと選ぶ。
            // atom でなくなったので、ProseMirror は押しても node を選ばない。
            handleClickOn(view: any, _pos: number, node: any, nodePos: number, event: MouseEvent) {
              if (node.type.name !== "imageItem") return false;
              const target = event.target as HTMLElement | null;
              if (target?.closest("figcaption")) return false;
              view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, nodePos)));
              return true;
            },
          },
        }),
      ];
    },

    addNodeView() {
      return ({ node, getPos, editor, view }: ViewArgs) => {
        const dom = document.createElement("figure");
        dom.className = "tt-image";

        const img = document.createElement("img");
        const note = document.createElement("span");
        note.className = "tt-image-note";
        // キャプションは画像の直下の figcaption で、本文と同じ contentDOM。
        // 代替テキストは、画像の上に浮く帯（ALT）から。値があっても最初から開かない。
        //
        // WhyNot: 代替テキストを画像の下に並べない。note は画像の下に説明文の欄が 1 つだけで、
        // alt は画像の上の帯から開く別の操作。読んでいる間に読まない欄があると本文が
        // 間延びする（`docs/design/richtext-note-style.md` 6.4）。
        const caption = document.createElement("figcaption");
        caption.className = "tt-image-caption";
        // 出典は contentDOM の外。値がある時だけキャプションの下に「出典: …」と出し、押すと帯が 2 欄の入力になる。
        // 新しく付けるのは Markdown / API から（帯には無い。note の画像の帯にも無い）。
        const source = document.createElement("button");
        source.type = "button";
        source.className = "tt-image-source";
        source.hidden = true;

        // 画像の上に浮く帯。中身は mode で入れ替わる（帯の下に面を足さない。note と同じ）。
        //
        // WhyNot: 本文の流れに置かない。開く度に下の本文が押し下がる。
        const bar = barOf({ className: "tt-image-bar" });
        bar.hidden = true;
        let mode: BarMode = "tools";

        const current = () => {
          const pos = getPos();
          if (pos === undefined) return null;
          const found = view.state.doc.nodeAt(pos);
          return found ? { pos, node: found } : null;
        };
        const writeAll = (changes: Record<string, string | null>) => {
          const found = current();
          if (!found) return;
          const next = { ...found.node.attrs };
          let changed = false;
          for (const [name, value] of Object.entries(changes)) {
            const normalized = value === "" ? null : value;
            if ((found.node.attrs[name] ?? null) === normalized) continue;
            next[name] = normalized;
            changed = true;
          }
          if (!changed) return;
          const state = view.state;
          const tr = state.tr.setNodeMarkup(found.pos, undefined, next);
          // node ごと選んだまま attrs を変えても、帯が消えないように選び直す（NodeSelection は写像で外れる事がある）。
          if (state.selection instanceof NodeSelection && state.selection.from === found.pos) tr.setSelection(NodeSelection.create(tr.doc, found.pos));
          view.dispatch(tr);
        };

        // WhyNot: 帯を文字にしない。note と同じくアイコンで、語は title / aria-label に持つ
        // （文字だと帯が画像より横に広がる）。ALT だけは note と同じく英字のまま。
        const label = (button: HTMLButtonElement, title: string) => {
          button.title = title;
          button.setAttribute("aria-label", title);
        };
        const tool = (icon: string | null, title: string, onClick: () => void) => {
          const button = document.createElement("button");
          button.type = "button";
          button.className = icon ? "tt-image-tool tt-image-icon" : "tt-image-tool";
          if (icon) button.innerHTML = svg(icon, BAR_ICON);
          else button.textContent = "ALT";
          label(button, title);
          // mousedown を止めないと ProseMirror が node の選択を外し、帯ごと消える。
          button.addEventListener("mousedown", (event) => event.preventDefault());
          button.addEventListener("click", onClick);
          return button;
        };
        const setMode = (next: BarMode, refocus: boolean) => {
          mode = next;
          render();
          if (mode === "tools" && refocus) view.focus();
        };

        // tools: リンク / ALT / 縮小 / 配置 / 横に並べる / 削除。
        // 並べた中の 1 枚は リンク / ALT / 削除（`docs/design/richtext-gallery-flow.html` 3）。
        // 「1 枚ずつに戻す」は並べた物ぜんたいの帯にあり、1 枚の帯には出さない。
        //
        // WhyNot: 帯に「キャプション」を置かない。欄は画像の下に出ていて押せば入力できる。
        // note の帯にも無い。
        const linkTool = tool(ICONS.link, "リンク", () => setMode("href", false));
        const altTool = tool(null, "代替テキスト", () => setMode("alt", false));
        const smallTool = tool(ICONS.shrink, "縮小", () => {
          const found = current();
          if (!found) return;
          writeAll({ size: found.node.attrs.size === SMALL ? null : SMALL });
          view.focus();
        });
        const alignTool = tool(ICONS.alignCenter, "配置", () => setMode("align", false));
        // 1 枚だけの image が隣り合っている時だけ出す。押すと続きの image を 1 つに畳む。
        const rowTool = tool(ICONS.columns, "横に並べる", () => {
          const pos = getPos();
          if (pos !== undefined) foldImages(view, imagePosOf(view.state.doc, pos));
        });
        const trashTool = tool(ICONS.trash, "削除", () => {
          const found = current();
          if (!found) return;
          view.dispatch(view.state.tr.delete(found.pos, found.pos + found.node.nodeSize));
          view.focus();
        });
        const toolsFor = (many: boolean, withRow: boolean) =>
          many ? [linkTool, altTool, trashTool] : [linkTool, altTool, smallTool, alignTool, ...(withRow ? [rowTool] : []), trashTool];
        const tools = [linkTool, altTool, smallTool, alignTool, rowTool, trashTool];

        // align: 左 / 中央 / 右。押すと書いて tools に戻る。
        const alignButtons = ALIGNS.map(({ value, icon, title }) => {
          const button = tool(icon, title, () => {
            writeAll({ align: value });
            setMode("tools", true);
          });
          button.dataset.align = value ?? "center";
          return { value, button };
        });

        // 入力: 欄 + 適用 + ×。
        const altField = barInput("代替テキスト", "tt-image-alt", false);
        const hrefField = barInput("https://", "tt-image-href", true);
        const sourceField = barInput("出典", "tt-image-source-name", false);
        const sourceUrlField = barInput("出典の URL", "tt-image-source-url", true);
        const fieldsOf = (key: BarMode): Array<[HTMLInputElement, string]> =>
          key === "alt" ? [[altField, "alt"]] : key === "href" ? [[hrefField, "href"]] : key === "source" ? [[sourceField, "source"], [sourceUrlField, "sourceUrl"]] : [];
        const apply = document.createElement("button");
        apply.type = "button";
        apply.className = "tt-image-apply";
        apply.textContent = "適用";
        apply.addEventListener("mousedown", (event) => event.preventDefault());
        apply.addEventListener("click", () => commit());
        const close = document.createElement("button");
        close.type = "button";
        close.className = "tt-image-close";
        close.textContent = "×";
        label(close, "閉じる");
        close.addEventListener("mousedown", (event) => event.preventDefault());
        close.addEventListener("click", () => setMode("tools", true));
        const commit = () => {
          const changes: Record<string, string | null> = {};
          for (const [input, name] of fieldsOf(mode)) changes[name] = input.value.trim();
          writeAll(changes);
          setMode("tools", true);
        };
        // 欄の中のキーはエディタにも Elm（Esc で画面を閉じる）にも漏らさない。
        bar.addEventListener("keydown", (event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            setMode("tools", true);
            return;
          }
          if (!(event.target instanceof HTMLInputElement)) return;
          event.stopPropagation();
          if (event.key === "Enter") {
            event.preventDefault();
            commit();
          }
        });

        // 並べている（親の image に 2 枚以上ある）間か。
        const withOthers = () => {
          const pos = getPos();
          return pos !== undefined && view.state.doc.resolve(pos).parent.childCount >= 2;
        };
        // 帯は node ごと選んでいる間か、tools 以外に入れ替わっている間（出典は選んでいなくても押せる）。
        const render = () => {
          const selected = dom.classList.contains("ProseMirror-selectednode");
          bar.hidden = !(selected || mode !== "tools");
          bar.classList.toggle("is-input", mode === "alt" || mode === "href" || mode === "source");
          if (mode === "tools") {
            const pos = getPos();
            if (pos === undefined) return;
            const many = withOthers();
            const doc = view.state.doc;
            const row = many ? 0 : adjacentImages(doc.resolve(imagePosOf(doc, pos))).length;
            bar.replaceChildren(...toolsFor(many, row >= 2));
            for (const button of tools) button.hidden = false;
            return;
          }
          if (mode === "align") {
            bar.replaceChildren(...alignButtons.map((entry) => entry.button));
            (bar.querySelector<HTMLElement>(".is-on") ?? alignButtons[1].button).focus();
            return;
          }
          const fields = fieldsOf(mode);
          const found = current();
          for (const [input, name] of fields) input.value = typeof found?.node.attrs[name] === "string" ? found.node.attrs[name] : "";
          for (const [input] of fields) input.dispatchEvent(new Event("input"));
          bar.replaceChildren(...fields.map(([input]) => input), apply, close);
          fields[0][0].focus();
          fields[0][0].select();
        };
        const back = () => {
          if (mode === "tools") return false;
          setMode("tools", false);
          return true;
        };
        openBars.add(back);
        // 帯の外を押したら tools に戻す（帯と「出典: …」の中は除く）。
        const onOutside = (event: MouseEvent) => {
          if (mode === "tools") return;
          const target = event.target as globalThis.Node | null;
          if (target && (bar.contains(target) || source.contains(target))) return;
          setMode("tools", false);
        };
        document.addEventListener("mousedown", onOutside, true);
        source.addEventListener("mousedown", (event) => event.preventDefault());
        source.addEventListener("click", () => (mode === "source" ? setMode("tools", true) : setMode("source", false)));

        dom.append(bar, img, note, caption, source);

        const paint = (next: Record<string, unknown>) => {
          paintImage(dom, img, note, store, next);
          // 幅と寄せは data 属性で当てる（`.tt-image[data-size=small]` など）。
          const small = next.size === SMALL;
          if (small) dom.dataset.size = SMALL;
          else delete dom.dataset.size;
          const align = typeof next.align === "string" ? next.align : null;
          if (align) dom.dataset.align = align;
          else delete dom.dataset.align;
          // 縮小している間は同じボタンが「拡大」になる（押すと戻る）。
          smallTool.innerHTML = svg(small ? ICONS.expand : ICONS.shrink, BAR_ICON);
          label(smallTool, small ? "拡大" : "縮小");
          smallTool.classList.toggle("is-on", small);
          smallTool.setAttribute("aria-pressed", String(small));
          // 帯の配置のアイコンは今の寄せ。3 つに入れ替えた時は今の寄せが is-on。
          alignTool.innerHTML = svg(ALIGNS.find((entry) => entry.value === align)?.icon ?? ICONS.alignCenter, BAR_ICON);
          for (const entry of alignButtons) {
            entry.button.classList.toggle("is-on", entry.value === align);
            entry.button.setAttribute("aria-pressed", String(entry.value === align));
          }
          const linked = typeof next.href === "string" && next.href !== "";
          linkTool.classList.toggle("is-on", linked);
          linkTool.setAttribute("aria-pressed", String(linked));
          // 値が入っているリンク / ALT は緑（掛かっている印。縮小中・今の配置と同じ規則）。
          const hasAlt = typeof next.alt === "string" && next.alt !== "";
          altTool.classList.toggle("is-on", hasAlt);
          altTool.setAttribute("aria-pressed", String(hasAlt));
          // 出典は source か sourceUrl のどちらかがある時だけ。URL があればリンク風に見せる。
          const sourceText = typeof next.source === "string" ? next.source : "";
          const sourceUrl = typeof next.sourceUrl === "string" ? next.sourceUrl : "";
          source.hidden = sourceText === "" && sourceUrl === "";
          source.replaceChildren();
          if (!source.hidden) {
            const cite = document.createElement("cite");
            cite.textContent = sourceText !== "" ? sourceText : sourceUrl;
            source.append("出典: ", cite);
            source.classList.toggle("is-linked", sourceUrl !== "");
            source.title = sourceUrl !== "" ? sourceUrl : "出典";
          }
          if (mode === "tools") render();
        };

        paint(node.attrs);
        dom.classList.toggle("is-empty", node.childCount === 0);
        let attrs = node.attrs;
        const stop = store.watch(() => paint(attrs));

        // 選んでいる（node ごと、またはキャプションの中）間だけ placeholder を出す。
        // 隣の node が変わっても update は来ないので、ここで「横に並べる」も出し直す。
        const syncActive = () => {
          const pos = getPos();
          if (pos === undefined) return;
          const selection = editor.state.selection;
          const size = editor.state.doc.nodeAt(pos)?.nodeSize ?? 1;
          const active = selection.from >= pos && selection.to <= pos + size;
          dom.classList.toggle("is-active", active);
          if (mode === "tools") render();
        };
        editor.on("transaction", syncActive);
        syncActive();

        return {
          dom,
          contentDOM: caption,
          // 帯と出典はこちらが描く物なので、触っても doc は動かさない。キャプションの中は ProseMirror に渡す。
          ignoreMutation: (mutation: { type: string; target: globalThis.Node }) =>
            mutation.type !== "selection" ? !caption.contains(mutation.target) : false,
          stopEvent: (event: Event) => {
            const target = event.target as globalThis.Node;
            return bar.contains(target) || source.contains(target);
          },
          update(updated: any) {
            if (updated.type.name !== "imageItem") return false;
            attrs = updated.attrs;
            paint(attrs);
            dom.classList.toggle("is-empty", updated.childCount === 0);
            return true;
          },
          selectNode() {
            dom.classList.add("ProseMirror-selectednode");
            render();
          },
          deselectNode() {
            dom.classList.remove("ProseMirror-selectednode");
            // 欄に焦点がある間は選択が外れても帯を残す（欄を押した時に一度外れる事がある）。
            if (!bar.contains(document.activeElement)) mode = "tools";
            render();
          },
          destroy() {
            stop();
            openBars.delete(back);
            editor.off("transaction", syncActive);
            document.removeEventListener("mousedown", onOutside, true);
          },
        };
      };
    },
  });
}

/** `imageItem` の位置から、包む `image` の位置。 */
function imagePosOf(doc: any, itemPos: number): number {
  const $pos = doc.resolve(itemPos);
  return $pos.before($pos.depth);
}

// `$pos` の指す image と、その前後に続く image の並び（doc の直下だけ）。
function adjacentImages($pos: any): Array<{ pos: number; node: any }> {
  const parent = $pos.parent;
  const index = $pos.index();
  const isImage = (i: number) => i >= 0 && i < parent.childCount && parent.child(i).type.name === "image";
  if (!isImage(index)) return [];
  let first = index;
  while (isImage(first - 1)) first -= 1;
  let last = index;
  while (isImage(last + 1)) last += 1;
  const run: Array<{ pos: number; node: any }> = [];
  let pos = $pos.start() + Array.from({ length: first }, (_, i) => parent.child(i).nodeSize).reduce((a, b) => a + b, 0);
  for (let i = first; i <= last; i += 1) {
    run.push({ pos, node: parent.child(i) });
    pos += parent.child(i).nodeSize;
  }
  return run;
}

// 隣り合う image を 1 つに畳む。畳んだ後は先頭の 1 枚を選んだままにする。
//
// WhyNot: node を作り直す形にしない。中の imageItem はそのまま持ち上げるので、
// キャプションも出典も畳む前の物が残る。
function foldImages(view: any, imagePos: number) {
  const state = view.state;
  const run = adjacentImages(state.doc.resolve(imagePos));
  if (run.length < 2) return;
  const items: any[] = [];
  for (const found of run) {
    found.node.forEach((item: any) => {
      // 並べている間は効かない attrs は落とす（CMS は並べた imageItem に size / align を受けない）。
      items.push(item.type.create({ ...item.attrs, size: null, align: null }, item.content, item.marks));
    });
  }
  const from = run[0].pos;
  const to = run[run.length - 1].pos + run[run.length - 1].node.nodeSize;
  const tr = state.tr.replaceWith(from, to, state.schema.nodes.image.create(null, items));
  tr.setSelection(NodeSelection.create(tr.doc, from + 1));
  view.dispatch(tr);
  view.focus();
}

// `imagePos` の image を 1 枚ずつの image に分ける。分けた後は先頭の 1 枚を選んだままにする。
function splitImages(view: any, imagePos: number) {
  const state = view.state;
  const image = state.doc.nodeAt(imagePos);
  if (!image || image.type.name !== "image" || image.childCount < 2) return;
  const singles: any[] = [];
  image.forEach((item: any) => singles.push(image.type.create(null, item)));
  const tr = state.tr.replaceWith(imagePos, imagePos + image.nodeSize, singles);
  tr.setSelection(NodeSelection.create(tr.doc, imagePos + 1));
  view.dispatch(tr);
  view.focus();
}

/** 画像の入れ物。中は `imageItem` の並びで、attrs は持たない。 */
export function imageNode(_store: AssetStore) {
  return Node.create({
    name: "image",
    group: "block",
    // WhyNot: `imageItem*` にしない。空の image を作れると、隣に画像を入れた時に
    // ProseMirror が先にある image へ中身を吸わせ、元の 1 枚が消える（実際に消えた）。
    // 最後の 1 枚の削除は帯が image ごと落とす。
    content: "imageItem+",
    // WhyNot: 素の block にしない。**下の段落に画像を入れると前の image が置き換わる。**
    // 入れる場所を探す時に前の image まで範囲が広がるので、境目を閉じる
    //（`defining` は使わない。型だけ残して中身を既定の imageItem で埋め直し、assetId が消える）。
    isolating: true,

    parseHTML() {
      return [{ tag: "div[data-gallery]" }, { tag: "figure[data-gallery]" }];
    },

    renderHTML() {
      return ["figure", { "data-gallery": "" }, 0];
    },

    addNodeView() {
      return ({ node, getPos, editor, view }: ViewArgs) => {
        const dom = document.createElement("div");

        // 並べた物ぜんたいの帯。1 枚ずつに戻す / 削除 の 2 つだけ
        // （`docs/design/richtext-gallery-flow.html` 2。縮小と配置は列の幅が決まっていて効かない）。
        //
        // WhyNot: 中の 1 枚の帯に「1 枚ずつに戻す」を置かない。1 枚を選んだつもりで押すと
        // 並びごと解ける。ぜんたいと 1 枚で帯を分ける（枠も外側と内側で分かれている）。
        const bar = barOf({ className: "tt-image-bar tt-gallery-tools" });
        bar.hidden = true;
        const tool = (icon: string, title: string, onClick: () => void) =>
          iconButton({ className: "tt-image-tool tt-image-icon", icon: svg(icon, BAR_ICON), title, onClick });
        bar.append(
          tool(ICONS.image, "1 枚ずつに戻す", () => {
            const pos = getPos();
            if (pos !== undefined) splitImages(view, pos);
          }),
          tool(ICONS.trash, "削除", () => {
            const pos = getPos();
            const found = pos === undefined ? null : view.state.doc.nodeAt(pos);
            if (pos === undefined || !found) return;
            view.dispatch(view.state.tr.delete(pos, pos + found.nodeSize));
            view.focus();
          })
        );
        dom.append(bar);

        const grid = document.createElement("div");
        dom.append(grid);

        // 列は枚数から決まるので、帯も select も無い（`docs/design/richtext-gallery-ui.md` 2）。
        // 1 枚の時は入れ物を素の div にして、今までの単独の画像と同じ見た目にする。
        const paint = (count: number) => {
          const many = count >= 2;
          dom.className = many ? "tt-images tt-gallery" : "tt-images";
          grid.className = many ? "tt-gallery-grid" : "tt-images-one";
          dom.dataset.count = String(count);
          grid.style.gridTemplateColumns = many ? `repeat(${columnsFor(count)}, minmax(0, 1fr))` : "";
          if (!many) bar.hidden = true;
        };
        paint(node.childCount);

        return {
          dom,
          contentDOM: grid,
          update(updated: any) {
            if (updated.type.name !== "image") return false;
            paint(updated.childCount);
            return true;
          },
          selectNode() {
            dom.classList.add("ProseMirror-selectednode");
            // 1 枚だけの時はぜんたいの帯を出さない（「1 枚ずつに戻す」が意味を持たない）。
            bar.hidden = (view.state.doc.nodeAt(getPos() ?? -1)?.childCount ?? 0) < 2;
          },
          deselectNode() {
            dom.classList.remove("ProseMirror-selectednode");
            bar.hidden = true;
          },
        };
      };
    },

    addProseMirrorPlugins() {
      return [emptyImagePlugin(), imageFramePlugin()];
    },
  });
}

// 並べた物ぜんたいを選ぶ道。**中の画像の外側（列の隙間と枠の余白）を押した時だけ。**
// 画像そのものを押した時は imageItem の plugin が 1 枚を選ぶので、ここへは来ない。
function imageFramePlugin() {
  return new Plugin({
    key: new PluginKey("imageFrameClick"),
    props: {
      handleClickOn(view: any, _pos: number, node: any, nodePos: number, event: MouseEvent) {
        if (node.type.name !== "image") return false;
        const target = event.target as HTMLElement | null;
        if (target?.closest(".tt-image") || target?.closest(".tt-image-bar")) return false;
        view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, nodePos)));
        return true;
      },
    },
  });
}

// 中身が 0 枚になった image を node ごと落とす（空の image は CMS が断る）。
function emptyImagePlugin() {
  return new Plugin({
    key: new PluginKey("imageNotEmpty"),
    appendTransaction(transactions: readonly { docChanged: boolean }[], _old: any, next: any) {
      if (!transactions.some((transaction) => transaction.docChanged)) return null;
      const found: Array<{ pos: number; size: number }> = [];
      next.doc.descendants((node: any, pos: number) => {
        if (node.type.name === "image" && node.childCount === 0) found.push({ pos, size: node.nodeSize });
      });
      if (found.length === 0) return null;
      const tr = next.tr;
      for (const one of found.reverse()) tr.delete(tr.mapping.map(one.pos), tr.mapping.map(one.pos + one.size));
      return tr;
    },
  });
}

/** 送っている間の仮の見た目。**保存には出さない**（`unfold` が落とす）。 */
export const UploadingImage = Node.create({
  name: "uploading",
  group: "block",
  atom: true,

  addAttributes() {
    return { token: { default: null }, name: { default: null } };
  },

  parseHTML() {
    return [{ tag: "div[data-uploading]" }];
  },

  renderHTML() {
    return ["div", { "data-uploading": "" }];
  },

  addNodeView() {
    return ({ node }: ViewArgs) => {
      const dom = document.createElement("div");
      dom.className = "tt-uploading";
      const spinner = document.createElement("span");
      spinner.className = "tt-uploading-spin";
      const label = document.createElement("span");
      label.textContent = `${typeof node.attrs.name === "string" ? node.attrs.name : "画像"} を送信中…`;
      dom.append(spinner, label);
      return { dom };
    };
  },
});

function imageFilesOf(data: DataTransfer | null): File[] {
  if (!data) return [];
  return Array.from(data.files).filter((file) => file.type.startsWith("image/"));
}

/** 貼り付けとドロップで来た画像のファイルを外に渡す。 */
export function imageDropExtension(onFiles: (files: File[]) => void) {
  return Extension.create({
    name: "imageDrop",
    addProseMirrorPlugins() {
      return [
        new Plugin({
          key: new PluginKey("imageDrop"),
          props: {
            handlePaste(_view: unknown, event: ClipboardEvent) {
              const files = imageFilesOf(event.clipboardData);
              if (files.length === 0) return false;
              event.preventDefault();
              onFiles(files);
              return true;
            },
            handleDrop(view: any, event: DragEvent) {
              const files = imageFilesOf(event.dataTransfer);
              if (files.length === 0) return false;
              event.preventDefault();
              // 落とした所に入れる。カーソルを先に move してから積む。
              const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
              if (at) view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(at.pos))));
              onFiles(files);
              return true;
            },
          },
        }),
      ];
    },
  });
}

/** 1 枚ぶんの `image`（上がり終わった画像を仮の見た目と差し替える所で使う）。 */
export function imageOf(schema: any, assetId: string): any {
  return schema.nodes.image.create(null, schema.nodes.imageItem.create({ assetId }));
}

/** 選んだメディアを本文に入れる形。**2 枚以上でも `image` 1 つで、中に並べる。** */
export function insertionOf(assetIds: string[]): Record<string, unknown> | null {
  const items = assetIds.filter((id) => id).map((id) => ({ type: "imageItem", attrs: { assetId: id } }));
  if (items.length === 0) return null;
  return { type: "image", content: items };
}

/**
 * 書く時に、キャプションの先頭と末尾の空白を落とす。空白だけなら中身を空にする。
 * WhyNot: CMS 側で trim しない。Markdown に写すと `* cap*` が箇条書きに見えるので、画面で落とした形を正とする。
 */
export function trimCaption(node: any): any {
  if (!node || typeof node !== "object" || node.type !== "imageItem" || !Array.isArray(node.content)) return node;
  const content = node.content.map((child: any) => ({ ...child }));
  const cut = (index: number, pattern: RegExp) => {
    const child = content[index];
    if (!child || typeof child.text !== "string") return;
    child.text = child.text.replace(pattern, "");
  };
  while (content.length > 0) {
    cut(0, /^\s+/);
    if (content[0].text !== "") break;
    content.shift();
  }
  while (content.length > 0) {
    cut(content.length - 1, /\s+$/);
    if (content[content.length - 1].text !== "") break;
    content.pop();
  }
  return { ...node, content };
}

/**
 * 旧い形を読む時だけ新しい形に写す。書く時は新しい形しか出さない。
 * - `gallery`（中に image を並べた物）→ `image`（中は imageItem。attrs.columns は捨てる）
 * - `attrs.assetId` を持つ `image`（1 枚）→ `image > imageItem`
 */
export function liftImageItems(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(liftImageItems) } : { ...node };
  if (next.type === "gallery") {
    const items = (Array.isArray(next.content) ? next.content : [])
      .filter((child: any) => child?.type === "image" || child?.type === "imageItem")
      .flatMap((child: any) => (child.type === "imageItem" ? [child] : Array.isArray(child.content) && !child.attrs?.assetId ? child.content : [{ ...child, type: "imageItem" }]));
    return { type: "image", content: items };
  }
  if (next.type !== "image" || typeof next.attrs?.assetId !== "string") return next;
  return { type: "image", content: [{ type: "imageItem", attrs: next.attrs, content: Array.isArray(next.content) ? next.content : [] }] };
}

/** 旧い形（attrs.caption の文字列）を、読む時だけ中身（text）に写す。書く時は中身しか出さない。 */
export function liftCaption(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(liftCaption) } : { ...node };
  if (next.type !== "imageItem" || typeof next.attrs?.caption !== "string") return next;
  const { caption, ...attrs } = next.attrs;
  const empty = !Array.isArray(next.content) || next.content.length === 0;
  return {
    ...next,
    attrs,
    content: empty && caption !== "" ? [{ type: "text", text: caption }] : next.content ?? [],
  };
}
