// エディタの中の DOM の部品（`docs/design/editor-dom-parts.md`）。
//
// ProseMirror が DOM を所有している所へ手書きの DOM を足すと、同じ形のバグが繰り返し出る。
// 帯に文字が打てる・浮く面がスクロールで取り残される・矢印キーが食われて外に出られない、の 3 つが
// 大半なので、そこだけを部品にして「作った時点で塞がっている」形にする。
//
// WhyNot: 見た目はここで決めない。class は呼ぶ側が渡し、色や大きさは `src/styles.css` に置く。
// 部品が見た目まで持つと、既にある帯を差し替えた瞬間に全部の帯の見た目が変わる。

import { TextSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";
import { dismissOn } from "./dismiss";

/** 帯と浮く面が必ず持つ class。`user-select` と `contenteditable` の保証はこれに掛かる。 */
export const BAR_CLASS = "tt-block-bar";
export const POP_CLASS = "tt-block-pop";

/** 浮く面の高さの上限。画面の半分を超えると、面だけで本文が読めなくなる。 */
const POP_MAX = 16 * 16;
/** これより低い所には出さない（2 行も読めない面は出しても押せない）。 */
const POP_MIN = 120;
/** 画面の端との隙間。 */
const EDGE = 8;

/** 押した所が、この帯（面）自身が持つ欄・ボタンか。**遡るのは `dom` まで**。
 *
 * WhyNot: `target.closest(...)` で済ませない。帯は本文の中に置かれるので、遡ると必ず
 * `contenteditable="true"` の本文に当たる。どこを押しても「中の欄を押した」と読まれ、
 * 下の `blockCaret` が 1 度も働かない（帯のどれを押しても焦点が本文に残ったままだった）。
 */
const OWN_CONTROL = "input, textarea, select, button, a, [contenteditable='true']";
function hasOwnControl(dom: HTMLElement, target: Element): boolean {
  for (let node: Element | null = target; node && node !== dom; node = node.parentElement)
    if (node.matches(OWN_CONTROL)) return true;
  return false;
}

/** 自分の中の欄とボタン以外を押した時、キャレットを置かせない。
 *
 * WhyNot: `contenteditable="false"` だけで済ませない。それは「打てない」だけで、欄と欄の間の
 * 余白を押すとキャレットは出る（点滅する棒が帯の真ん中に立つ）。押し始めを止めれば出ない。
 * WhyNot: `caret-color: transparent` で隠さない。中の入力のキャレットまで消える。
 */
function blockCaret(dom: HTMLElement) {
  dom.addEventListener("mousedown", (event) => {
    const target = event.target;
    if (target instanceof Element && hasOwnControl(dom, target)) return;
    event.preventDefault();
    // WhyNot: 押し始めを止めるだけで終わらせない。本文の焦点と選択がそのまま残るので、
    // 帯の余白を押した後に打った字が、さっきまでカーソルが居た所へ入る（帯には出ないが doc に入る）。
    // 帯そのものに焦点を移せば、打っても行き先が無い。
    dom.focus({ preventScroll: true });
  });
}

type BarArgs = {
  /** 見た目の class（`tt-code-bar` など）。`tt-block-bar` は部品が足す。 */
  className: string;
  children?: (HTMLElement | null)[];
};

/** ブロックの帯。作った時点で文字が打てない。
 *
 * WhyNot: `stopEvent` だけに任せない。帯は node view の DOM の中なので、欄と欄の間の余白を
 * 押すとそこに文字が打ててしまう（doc には入らず帯の DOM にだけ残る）。`contenteditable="false"`
 * にすると打てなくなり、中の欄とボタンの操作はそのまま効く。
 */
export function bar(args: BarArgs): HTMLElement {
  const dom = document.createElement("div");
  dom.className = `${BAR_CLASS} ${args.className}`;
  dom.contentEditable = "false";
  // 余白を押した時の焦点の行き先。Tab の順番には入れない。
  dom.tabIndex = -1;
  blockCaret(dom);
  for (const child of args.children ?? []) if (child) dom.appendChild(child);
  return dom;
}

export type Side = "below" | "above";
export type Align = "start" | "end";

type PopArgs = {
  /** 面を入れる親。`position: static` なら `relative` を付ける。 */
  anchor: HTMLElement;
  place?: { side?: Side; align?: Align; gap?: number };
  className: string;
  /** 外を押した / Esc で閉じた後に呼ばれる。 */
  onClose?: () => void;
  /** この中を押しても閉じない（開く側のボタン・欄）。 */
  keep?: HTMLElement[];
  /** この枠から出さない（本文の枠）。省略すると画面だけを見る。
   *
   * WhyNot: 画面に収まっていれば良い事にしない。本文の一番下の段落で開いた面は、画面には
   * 収まっていても本文の枠を越えて下のフィールドに重なる（実際に重なった）。
   */
  bounds?: HTMLElement;
};

export type Popover = {
  dom: HTMLElement;
  /** `at` は親の中で基準にする要素（省略すると親そのもの）。 */
  open(at?: HTMLElement): void;
  close(): void;
  readonly isOpen: boolean;
  /** 本文が動いた時に置き直す。 */
  place(): void;
  destroy(): void;
};

/** 浮く面。**親を基準に置く**（`position: absolute` + 親に `relative`）。
 *
 * WhyNot: 画面座標（`position: fixed`）で置かない。開いた時の座標しか測っていないので、
 * 本文を送ると面だけが元の高さに取り残される（実際に離れた）。親の中に置けば、親が動けば
 * 面も動くので測り直しが要らない。
 */
export function popover(args: PopArgs): Popover {
  const side = args.place?.side ?? "below";
  const align = args.place?.align ?? "start";
  const gap = args.place?.gap ?? 6;

  // WhyNot: 作った時に親の position を測らない。node view の DOM はまだ文書に付いていない事が
  // あり、その間の `getComputedStyle` は空を返す（relative が付かないまま親を飛び越えて置かれる）。
  // 開く時に測る。
  const ensureBase = () => {
    if (window.getComputedStyle(args.anchor).position === "static") args.anchor.style.position = "relative";
  };

  const dom = document.createElement("div");
  dom.className = `${POP_CLASS} ${args.className}`;
  dom.hidden = true;
  // 面も手書きの DOM なので、帯と同じく文字を打てなくする。
  dom.contentEditable = "false";
  dom.style.position = "absolute";
  blockCaret(dom);
  args.anchor.appendChild(dom);

  let at: HTMLElement = args.anchor;
  let undismiss: (() => void) | null = null;
  let open = false;

  const place = () => {
    if (dom.hidden) return;
    const base = args.anchor.getBoundingClientRect();
    const mark = at === args.anchor ? base : at.getBoundingClientRect();

    // 幅は先に決める（横に溢れると中身が折り返して高さが変わる）。
    dom.style.maxWidth = `${window.innerWidth - EDGE * 2}px`;

    // **上下は「入る方」に出し、それでも余らない時は上限を詰める。**
    //
    // WhyNot: 中身の高さのまま置かない。言語の候補のように行が増える面は、コードブロックの枠も
    // 画面も突き抜けて下まで伸びる（実際に伸びた）。入る高さに切って中で送らせる。
    dom.style.maxHeight = "";
    const wants = dom.getBoundingClientRect().height;
    // 出て良い縦の範囲は、画面と（あれば）本文の枠の狭い方。
    const frame = args.bounds?.getBoundingClientRect();
    const floor = Math.min(window.innerHeight - EDGE, frame ? frame.bottom : Number.POSITIVE_INFINITY);
    const ceil = Math.max(EDGE, frame ? frame.top : Number.NEGATIVE_INFINITY);
    const roomBelow = floor - (mark.bottom + gap);
    const roomAbove = mark.top - gap - ceil;
    const first = side === "below" ? roomBelow : roomAbove;
    const other = side === "below" ? roomAbove : roomBelow;
    // 望んだ側に入らず、反対側の方が広い時だけ返す。
    const flipped = wants > first && other > first;
    const room = flipped ? other : first;
    const limit = Math.min(POP_MAX, Math.max(room, POP_MIN));
    dom.style.maxHeight = `${Math.round(limit)}px`;
    dom.style.overflowY = "auto";

    const height = Math.min(wants, limit);
    const below = mark.bottom - base.top + gap;
    const above = mark.top - base.top - height - gap;
    const wanted = side === "below" ? !flipped : flipped;
    dom.style.top = `${Math.round(wanted ? below : above)}px`;

    // 左右。基準の端に揃え、画面からはみ出す分だけ内へ寄せる（返しはしない）。
    const width = dom.getBoundingClientRect().width;
    const start = mark.left - base.left;
    const end = mark.right - base.left - width;
    let left = align === "start" ? start : end;
    const screen = base.left + left;
    if (screen + width > window.innerWidth - EDGE) left -= screen + width - (window.innerWidth - EDGE);
    if (base.left + left < EDGE) left += EDGE - (base.left + left);
    dom.style.left = `${Math.round(left)}px`;
    // WhyNot: `right` を空のままにしない。既にある CSS が `right` を持っていると
    // `left` と両立して面が引き伸ばされる。
    dom.style.right = "auto";
    dom.style.bottom = "auto";
  };

  const onResize = () => place();

  const close = () => {
    if (!open) return;
    open = false;
    undismiss?.();
    undismiss = null;
    dom.hidden = true;
    window.removeEventListener("resize", onResize);
    args.onClose?.();
  };

  return {
    dom,
    get isOpen() {
      return open;
    },
    open(mark?: HTMLElement) {
      at = mark ?? args.anchor;
      ensureBase();
      dom.hidden = false;
      open = true;
      place();
      window.addEventListener("resize", onResize);
      undismiss?.();
      undismiss = dismissOn({ inside: [dom, ...(args.keep ?? [])], onClose: close });
    },
    close,
    place,
    destroy() {
      close();
      dom.remove();
    },
  };
}

type FieldArgs = {
  className: string;
  placeholder: string;
  /** 読み上げの名前。省略すると placeholder と同じ。 */
  label?: string;
  value?: string;
  type?: "text" | "url";
  /** Enter と blur で呼ぶ。 */
  onCommit?: (value: string) => void;
  /** 端の行で上下の矢印を押した。`-1` が上、`1` が下。 */
  onLeave?: (dir: -1 | 1) => void;
  /** 押し始め。置きっぱなしの疑似行を消す等。 */
  onDown?: () => void;
  onInput?: (value: string) => void;
  onEscape?: () => void;
};

/** ブロックの中の入力。
 *
 * WhyNot: placeholder を自前の要素で出さない。中身が空かどうかを自分で見張る事になり、
 * 外から値を入れた時に消し忘れる（引用の出典で実際に残った）。素の `<input placeholder>` に任せる。
 *
 * WhyNot: 上下の矢印を `stopEvent` に任せない。帯の中の鍵は node view が全部食べるので、
 * 矢印が `BlockEdges` に届かず、欄を打っている間は前後の行へ移れない。
 */
export function field(args: FieldArgs): HTMLInputElement {
  const dom = document.createElement("input");
  dom.type = args.type ?? "text";
  dom.className = args.className;
  dom.placeholder = args.placeholder;
  dom.setAttribute("aria-label", args.label ?? args.placeholder);
  dom.value = args.value ?? "";

  dom.addEventListener("mousedown", () => args.onDown?.());
  dom.addEventListener("blur", () => args.onCommit?.(dom.value));
  if (args.onInput) dom.addEventListener("input", () => args.onInput?.(dom.value));
  dom.addEventListener("keydown", (event) => {
    // 全選択はブラウザの既定（この欄の中だけ）に任せる。
    // WhyNot: ここで preventDefault しない。欄の中の全選択はブラウザが正しく持っている。
    // 上へ伝えないのは、本文の全選択に化けるのを止めるため。
    if (isSelectAll(event)) {
      event.stopPropagation();
      return;
    }
    // WhyNot: Enter でここから直に書かない。blur が同じ物を書くので 2 回書く事になる。
    // 欄を抜けるだけにして、書くのは blur の 1 本に寄せる。
    if (event.key === "Enter" && args.onCommit) {
      event.preventDefault();
      dom.blur();
      return;
    }
    if (event.key === "Escape" && args.onEscape) {
      event.preventDefault();
      args.onEscape();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return;
    if (!args.onLeave) return;
    event.preventDefault();
    args.onCommit?.(dom.value);
    args.onLeave(event.key === "ArrowUp" ? -1 : 1);
  });
  return dom;
}

type IconArgs = {
  className: string;
  /** `icons.ts` の `svg(...)` が返す文字列。 */
  icon: string;
  title: string;
  onClick: () => void;
  /** 掛かっている / いないを出す。省略すると `aria-pressed` を出さない。 */
  pressed?: boolean;
  /** mousedown を止める（ProseMirror に選択を外させない）。既定は止める。 */
  keepSelection?: boolean;
};

/** アイコンだけのボタン。`title` と `aria-label` が必ず入る（文言の見張りに乗る）。 */
export function iconButton(args: IconArgs): HTMLButtonElement {
  const dom = document.createElement("button");
  dom.type = "button";
  dom.className = args.className;
  dom.innerHTML = args.icon;
  dom.title = args.title;
  dom.setAttribute("aria-label", args.title);
  if (args.pressed !== undefined) dom.setAttribute("aria-pressed", String(args.pressed));
  // 止めないと ProseMirror が node の選択を外し、帯ごと消える。
  if (args.keepSelection !== false) dom.addEventListener("mousedown", (event) => event.preventDefault());
  dom.addEventListener("click", () => args.onClick());
  return dom;
}

/** macOS（と iPad / iPhone）か。修飾キーの意味が他と違う所で引く。 */
export function isMac(): boolean {
  const agent = navigator as Navigator & { userAgentData?: { platform?: string } };
  // WhyNot: `??` で繋がない。`userAgentData.platform` は空の文字列を返す事があり（実際に返った）、
  // 空は `??` を素通りするので `navigator.platform` まで落ちない。
  const platform = agent.userAgentData?.platform || navigator.platform || navigator.userAgent;
  // WhyNot: 大文字小文字を区別しない。`userAgentData.platform` は "macOS" を返し（先頭が小文字）、
  // `/Mac/` では当たらない（実際に外れて、Mac で Control+A が全選択になった）。
  return /mac|iphone|ipad/i.test(platform);
}

/** 全選択か。**macOS は Command だけ。**
 *
 * WhyNot: macOS で Control+A を全選択として受けない。OS 全体で「行頭へ移動」（Emacs 由来。
 * Control+E が行末、Control+K が行末まで削除）なので、受けるとその操作を奪う。
 */
export function isSelectAll(event: KeyboardEvent): boolean {
  if (event.key !== "a" && event.key !== "A") return false;
  if (event.altKey) return false;
  return isMac() ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
}

// 中にカーソルがある間、全選択をその中だけに閉じる node。
//
// WhyNot: 段落まで広げない。段落の ⌘A は本文全体を選ぶのが当たり前で、そこを変えると
// 「本文を全部消す」がどこからも押せなくなる。中を書き直す箱だけに掛ける。
//
// WhyNot: `image` と `blockquote` は入れない。textblock はキャプションの `imageItem` と
// 出典の `quoteCite` の方で、包む側の名前を書いても一度も当たらない。
const OWN_SELECT = new Set(["codeBlock", "imageItem", "quoteCite"]);

// 中の段落まで閉じる node。**セルの textblock は `paragraph`** なので、名前では当たらない。
//
// WhyNot: 段落の名前を OWN_SELECT に足さない。本文の段落まで巻き込んで、本文全体の ⌘A が
// どこからも押せなくなる。包む側を見る形にする。
const OWN_SELECT_PARENT = new Set(["tableCell", "tableHeader"]);

/** コードブロックや画像のキャプションの中の ⌘A を、その中だけの選択にする。
 *
 * WhyNot: 「2 回続けて押したら本文全体」の段階を付けない。1 回目と 2 回目で結果が変わると、
 * 押す前にどちらになるか分からない。中に居る間はいつでも中だけ。
 */
export function selectAllInBlock(view: EditorView, event: KeyboardEvent): boolean {
  if (!isSelectAll(event)) return false;
  const { state } = view;
  const { $from } = state.selection;
  if (!$from.parent.isTextblock) return false;
  const own =
    OWN_SELECT.has($from.parent.type.name) ||
    ($from.depth > 0 && OWN_SELECT_PARENT.has($from.node($from.depth - 1).type.name));
  if (!own) return false;
  view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, $from.start(), $from.end())));
  return true;
}

/** node view の `stopEvent` に渡す判定。帯と面の中の出来事は ProseMirror に渡さない。 */
export function owns(parts: (HTMLElement | null | undefined)[], event: Event): boolean {
  const target = event.target as globalThis.Node | null;
  if (!target) return false;
  return parts.some((part) => !!part && part.contains(target));
}

/** 浮く面が上へ逃げて良い下限（画面の座標）。貼り付いた道具の帯の下端。
 *
 * **`popover()` の `bounds` と同じ役目を、Floating UI で置く面（バブルメニュー）に渡すための物。**
 *
 * WhyNot: 画面の上端（0）を下限にしない。エディタの画面は上に「下書き保存 / 公開」の帯が
 * 貼り付いていて（`Page/Editor.elm` の `sticky top-0`、64px）、その下に道具の帯（`.tt-bar`）が
 * 続く。0 まで許すと選んだ文字が上の方にある時に帯がその裏へ潜り、タイトルと保存の表示を隠す。
 *
 * WhyNot: 64px と書かない。道具の帯は本文の枠の中で貼り付くので、本文を見ていない間は
 * 下限が上の帯の分だけで済む。実測すれば両方の場合で正しい値になる。
 */
export function stickyFloor(root: ParentNode): number {
  const bar = root.querySelector<HTMLElement>(".tt-bar");
  if (!bar) return 0;
  return Math.max(0, bar.getBoundingClientRect().bottom);
}

// 外のクリックと Esc で閉じる見張りは `dismiss.ts`（Elm の dismissLayer と揃えてある）。
// 浮く面を自前で組む所からも引けるよう、ここから出し直す。
export { dismissOn };
