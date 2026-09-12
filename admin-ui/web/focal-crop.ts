// メディアの注目点と切り抜き枠を決める custom element `<focal-crop>`。
//
// Elm からは属性（`src` / `width` / `height` / `focal-x` / `focal-y` / `crop-*` / `ratio` /
// `disabled` / `min-width` / `min-height`）で受け、決まったら `focal-crop-changed` の
// CustomEvent で返す。計算は `focal-crop-math.ts`（DOM を触らない）。
//
// WhyNot: ドラッグの途中で出さない。自動保存に乗せるので、動かしている間に出すと
// 1 回の操作で何十回も保存が走る。離した時と、矢印キーを離した時にだけ出す。
//
// WhyNot: 位置を getBoundingClientRect で測らない。掴んだ時の clientX / clientY からの
// 差だけを見れば足りる（差を舞台の幅で割れば割合になる）。舞台の大きさは clientWidth。
//
// WhyNot: 枠と印を ui.ts の popover() に載せない。あれは要素に添えて浮く面で、
// ここは絵の上の座標。舞台（画像を包む要素）に対する % で置き、舞台ごと送られても
// 取り残されない。

import { IMAGE_FAILED } from "./asset-thumb";
import {
  CENTER,
  FULL,
  PREVIEWS,
  centeredCrop,
  clampCrop,
  fitRatio,
  fitsOgp,
  format,
  fraction,
  keyStep,
  moveCrop,
  parseRatio,
  pinFocal,
  previewWindow,
  ratioValue,
  resizeCrop,
  type Crop,
  type Handle,
  type Point,
  type Ratio,
  type Size,
} from "./focal-crop-math";

export type FocalCropDetail = { focalPoint: Point; crop: Crop };

/** 出すイベントの名前。Elm 側の `on` と同じ字。 */
export const CHANGED = "focal-crop-changed";

/** OGP に足りない時の一言。 */
export const OGP_TOO_SMALL = "OGP には幅が足りません";

const HANDLES: ReadonlyArray<[Handle, string]> = [
  ["nw", "切り抜き枠の左上"],
  ["n", "切り抜き枠の上"],
  ["ne", "切り抜き枠の右上"],
  ["e", "切り抜き枠の右"],
  ["se", "切り抜き枠の右下"],
  ["s", "切り抜き枠の下"],
  ["sw", "切り抜き枠の左下"],
  ["w", "切り抜き枠の左"],
];

type Grab = { kind: "focal" } | { kind: "move" } | { kind: "handle"; handle: Handle };

type Drag = {
  grab: Grab;
  startX: number;
  startY: number;
  focal: Point;
  crop: Crop;
  moved: boolean;
};

const ARROWS: Record<string, [number, number]> = {
  ArrowLeft: [-1, 0],
  ArrowRight: [1, 0],
  ArrowUp: [0, -1],
  ArrowDown: [0, 1],
};

function cssUrl(src: string): string {
  return `url("${src.replace(/[\\"\n\r]/g, (c) => (c === "\n" || c === "\r" ? "" : "\\" + c))}")`;
}

class FocalCrop extends HTMLElement {
  static observedAttributes = [
    "src",
    "width",
    "height",
    "focal-x",
    "focal-y",
    "crop-left",
    "crop-top",
    "crop-width",
    "crop-height",
    "ratio",
    "disabled",
    "min-width",
    "min-height",
  ];

  private focal: Point = CENTER;
  private crop: Crop = FULL;
  private ratio: Ratio = "free";
  private drag: Drag | null = null;
  // 矢印キーで動かした分。キーを離した時に 1 回だけ出す。
  private keyDirty = false;
  // 最後に出した値。同じ値では出さない。
  private sent: FocalCropDetail | null = null;

  private stage: HTMLElement | null = null;
  private img: HTMLImageElement | null = null;
  private note: HTMLElement | null = null;
  private box: HTMLElement | null = null;
  private dot: HTMLElement | null = null;
  private handles: HTMLElement[] = [];
  private previews: HTMLElement[] = [];
  private ogpNote: HTMLElement | null = null;
  private focalText: HTMLElement | null = null;
  private cropText: HTMLElement | null = null;
  private reset: HTMLButtonElement | null = null;

  connectedCallback() {
    if (!this.stage) this.build();
    this.read();
    this.paint();
  }

  attributeChangedCallback(name: string) {
    if (!this.stage) return;
    if (name === "src") this.load();
    // 掴んでいる間は Elm から来た値で上書きしない（離した時の値を出す方が新しい）。
    if (!this.drag) this.read();
    this.paint();
  }

  disconnectedCallback() {
    this.endDrag(false);
  }

  /** 元の寸法。属性が無ければ読み込んだ画像の物。 */
  private size(): Size {
    const w = Number(this.getAttribute("width"));
    const h = Number(this.getAttribute("height"));
    if (w > 0 && h > 0) return { width: w, height: h };
    const img = this.img;
    if (img && img.naturalWidth > 0) return { width: img.naturalWidth, height: img.naturalHeight };
    return { width: 1, height: 1 };
  }

  private minOgp(): Size {
    const w = Number(this.getAttribute("min-width"));
    const h = Number(this.getAttribute("min-height"));
    return { width: w > 0 ? w : 1200, height: h > 0 ? h : 630 };
  }

  private get disabled(): boolean {
    return this.hasAttribute("disabled");
  }

  private build() {
    const stage = document.createElement("div");
    stage.className = "fc-stage";
    const img = document.createElement("img");
    img.alt = "";
    img.draggable = false;
    const note = document.createElement("span");
    note.className = "fc-note";
    note.textContent = IMAGE_FAILED;
    note.hidden = true;

    const box = document.createElement("div");
    box.className = "fc-box";
    box.setAttribute("role", "group");
    box.setAttribute("aria-label", "切り抜き枠");
    box.dataset.grab = "move";
    for (const [handle, label] of HANDLES) {
      const el = document.createElement("div");
      el.className = `fc-handle fc-handle-${handle}`;
      el.setAttribute("role", "slider");
      el.setAttribute("aria-label", label);
      el.dataset.grab = handle;
      box.append(el);
      this.handles.push(el);
    }
    const dot = document.createElement("div");
    dot.className = "fc-dot";
    dot.setAttribute("role", "slider");
    dot.setAttribute("aria-label", "注目点");
    dot.dataset.grab = "focal";
    stage.append(img, note, box, dot);

    const aside = document.createElement("div");
    aside.className = "fc-previews";
    for (const p of PREVIEWS) {
      const wrap = document.createElement("figure");
      wrap.className = "fc-preview";
      const view = document.createElement("div");
      view.className = `fc-preview-box fc-preview-${p.id}`;
      view.setAttribute("role", "img");
      view.setAttribute("aria-label", p.label);
      const cap = document.createElement("figcaption");
      cap.textContent = p.label;
      wrap.append(view, cap);
      if (p.id === "ogp") {
        const ogpNote = document.createElement("p");
        ogpNote.className = "fc-ogp-note";
        ogpNote.textContent = OGP_TOO_SMALL;
        ogpNote.hidden = true;
        wrap.append(ogpNote);
        this.ogpNote = ogpNote;
      }
      aside.append(wrap);
      this.previews.push(view);
    }

    const foot = document.createElement("div");
    foot.className = "fc-foot";
    const focalText = document.createElement("span");
    focalText.className = "fc-value";
    const cropText = document.createElement("span");
    cropText.className = "fc-value";
    const reset = document.createElement("button");
    reset.type = "button";
    reset.className = "fc-reset";
    reset.textContent = "元に戻す";
    reset.addEventListener("click", () => this.resetAll());
    foot.append(focalText, cropText, reset);

    this.append(stage, aside, foot);
    this.stage = stage;
    this.img = img;
    this.note = note;
    this.box = box;
    this.dot = dot;
    this.focalText = focalText;
    this.cropText = cropText;
    this.reset = reset;

    stage.addEventListener("pointerdown", this.onPointerDown);
    stage.addEventListener("keydown", this.onKeyDown);
    stage.addEventListener("keyup", this.onKeyUp);
    img.addEventListener("load", () => {
      note.hidden = true;
      img.hidden = false;
      if (!this.drag) this.read();
      this.paint();
    });
    img.addEventListener("error", () => {
      note.hidden = false;
      img.hidden = true;
    });
    this.load();
  }

  private load() {
    const img = this.img;
    if (!img) return;
    const src = this.getAttribute("src") ?? "";
    if (img.getAttribute("src") === src) return;
    if (src === "") {
      img.removeAttribute("src");
      return;
    }
    img.src = src;
  }

  /** 属性から値を読む。枠は比率と範囲に合わせて丸め、注目点は枠の中に押し込む。 */
  private read() {
    this.ratio = parseRatio(this.getAttribute("ratio"));
    const crop = clampCrop({
      left: fraction(this.getAttribute("crop-left"), 0),
      top: fraction(this.getAttribute("crop-top"), 0),
      width: fraction(this.getAttribute("crop-width"), 1),
      height: fraction(this.getAttribute("crop-height"), 1),
    });
    this.crop = fitRatio(crop, ratioValue(this.ratio), this.size(), "se");
    this.focal = pinFocal(
      { x: fraction(this.getAttribute("focal-x"), 0.5), y: fraction(this.getAttribute("focal-y"), 0.5) },
      this.crop,
    );
  }

  private paint() {
    const { box, dot, stage } = this;
    if (!box || !dot || !stage) return;
    const c = this.crop;
    const f = this.focal;
    const size = this.size();
    const pct = (n: number) => `${(n * 100).toFixed(3)}%`;
    box.style.inset = `${pct(c.top)} ${pct(1 - c.left - c.width)} ${pct(1 - c.top - c.height)} ${pct(c.left)}`;
    dot.style.inset = `${pct(f.y)} auto auto ${pct(f.x)}`;
    const text = format(f, c, size);
    dot.setAttribute("aria-valuetext", text.focal);
    box.setAttribute("aria-valuetext", text.crop);
    if (this.focalText) this.focalText.textContent = `注目点 ${text.focal}`;
    if (this.cropText) this.cropText.textContent = `切り抜き ${text.crop}`;

    const tab = this.disabled ? "-1" : "0";
    dot.tabIndex = Number(tab);
    box.tabIndex = Number(tab);
    for (const h of this.handles) {
      h.tabIndex = Number(tab);
      h.setAttribute("aria-valuetext", text.crop);
    }
    if (this.reset) this.reset.disabled = this.disabled;
    this.toggleAttribute("data-disabled", this.disabled);
    stage.classList.toggle("fc-dragging", this.drag !== null);

    const src = this.getAttribute("src") ?? "";
    PREVIEWS.forEach((p, i) => {
      const view = this.previews[i];
      if (!view) return;
      const w = previewWindow(c, f, size, p.box);
      view.style.backgroundImage = src === "" ? "none" : cssUrl(src);
      view.style.backgroundSize = `${w.size.x.toFixed(3)}% ${w.size.y.toFixed(3)}%`;
      view.style.backgroundPosition = `${w.position.x.toFixed(3)}% ${w.position.y.toFixed(3)}%`;
    });
    if (this.ogpNote) this.ogpNote.hidden = fitsOgp(c, size, this.minOgp());
  }

  private grabOf(target: EventTarget | null): Grab | null {
    if (!(target instanceof HTMLElement)) return null;
    const el = target.closest<HTMLElement>("[data-grab]");
    const grab = el?.dataset.grab;
    if (!grab || !this.stage?.contains(el)) return null;
    if (grab === "focal" || grab === "move") return { kind: grab };
    return { kind: "handle", handle: grab as Handle };
  }

  private onPointerDown = (e: PointerEvent) => {
    if (this.disabled || e.button !== 0) return;
    const grab = this.grabOf(e.target);
    if (!grab) return;
    e.preventDefault();
    (e.target as HTMLElement).focus?.();
    this.drag = { grab, startX: e.clientX, startY: e.clientY, focal: this.focal, crop: this.crop, moved: false };
    window.addEventListener("pointermove", this.onPointerMove);
    window.addEventListener("pointerup", this.onPointerUp);
    window.addEventListener("pointercancel", this.onPointerUp);
    this.paint();
  };

  private onPointerMove = (e: PointerEvent) => {
    const d = this.drag;
    const stage = this.stage;
    if (!d || !stage || stage.clientWidth === 0 || stage.clientHeight === 0) return;
    const dx = (e.clientX - d.startX) / stage.clientWidth;
    const dy = (e.clientY - d.startY) / stage.clientHeight;
    d.moved = true;
    this.apply(d.grab, d.focal, d.crop, dx, dy);
    this.paint();
  };

  private onPointerUp = () => this.endDrag(true);

  private endDrag(emit: boolean) {
    const d = this.drag;
    if (!d) return;
    this.drag = null;
    window.removeEventListener("pointermove", this.onPointerMove);
    window.removeEventListener("pointerup", this.onPointerUp);
    window.removeEventListener("pointercancel", this.onPointerUp);
    this.paint();
    if (emit && d.moved) this.emit();
  }

  /** 掴んだ物を (dx, dy) だけ動かした値を入れる。基準は掴んだ時の値。 */
  private apply(grab: Grab, focal: Point, crop: Crop, dx: number, dy: number) {
    if (grab.kind === "focal") {
      this.focal = pinFocal({ x: focal.x + dx, y: focal.y + dy }, crop);
      return;
    }
    const next =
      grab.kind === "move" ? moveCrop(crop, dx, dy) : resizeCrop(crop, grab.handle, dx, dy, ratioValue(this.ratio), this.size());
    this.crop = next;
    this.focal = pinFocal(this.focal, next);
  }

  private onKeyDown = (e: KeyboardEvent) => {
    if (this.disabled || this.drag) return;
    const arrow = ARROWS[e.key];
    const grab = this.grabOf(e.target);
    if (!arrow || !grab) return;
    e.preventDefault();
    const step = keyStep(e.shiftKey);
    let [dx, dy] = [arrow[0] * step, arrow[1] * step];
    // 上下の辺は横に、左右の辺は縦に動かない。
    if (grab.kind === "handle") {
      if (grab.handle === "n" || grab.handle === "s") dx = 0;
      if (grab.handle === "e" || grab.handle === "w") dy = 0;
      if (dx === 0 && dy === 0) return;
    }
    this.apply(grab, this.focal, this.crop, dx, dy);
    this.keyDirty = true;
    this.paint();
  };

  private onKeyUp = (e: KeyboardEvent) => {
    if (!ARROWS[e.key] || !this.keyDirty) return;
    this.keyDirty = false;
    this.emit();
  };

  private resetAll() {
    if (this.disabled) return;
    this.crop = centeredCrop(this.ratio, this.size());
    this.focal = pinFocal(CENTER, this.crop);
    this.paint();
    this.emit();
  }

  private emit() {
    const detail: FocalCropDetail = { focalPoint: { ...this.focal }, crop: { ...this.crop } };
    const same = (a: Record<string, number>, b: Record<string, number>) => Object.keys(a).every((k) => a[k] === b[k]);
    if (this.sent && same(this.sent.focalPoint, detail.focalPoint) && same(this.sent.crop, detail.crop)) return;
    this.sent = detail;
    this.dispatchEvent(new CustomEvent<FocalCropDetail>(CHANGED, { detail }));
  }
}

if (!customElements.get("focal-crop")) customElements.define("focal-crop", FocalCrop);
