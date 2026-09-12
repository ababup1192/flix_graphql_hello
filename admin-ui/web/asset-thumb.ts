// メディアの縮小画像。**読めなかった時に自前の断りを出す**ためだけの custom element。
//
// WhyNot: Elm の `Html.img` のままにしない。読めない時にブラウザが出す壊れた画像の印は
// ブラウザごとに違う絵で、何が起きたのかも次に何をすれば良いのかも伝えない。
// Elm から `error` を取るには msg と Model の持ち物が要り、メディアの一覧とエディタの
// 2 つの Model を触る事になる。**画面の状態ではなく画像の状態**なので、img の隣に置く。
//
// WhyNot: CSS だけで逃がさない。読み込みの失敗を当てられるセレクタは無い。
// 下に文字を敷いて上に `background-image` を重ねる手はあるが、透ける PNG で
// 下の文字が透けて出る。

/** 画像が読めなかった時の断り。**エディタの本文の画像（`image-node.ts`）と同じ字**を出す。 */
export const IMAGE_FAILED = "画像を読み込めませんでした";

class AssetThumb extends HTMLElement {
  static observedAttributes = ["src", "alt"];

  private img: HTMLImageElement | null = null;
  private note: HTMLElement | null = null;

  connectedCallback() {
    if (!this.img) {
      const img = document.createElement("img");
      img.alt = this.getAttribute("alt") ?? "";
      const note = document.createElement("span");
      note.className = "asset-thumb-note";
      note.textContent = IMAGE_FAILED;
      note.hidden = true;
      this.append(img, note);
      this.img = img;
      this.note = note;
    }
    this.paint();
  }

  attributeChangedCallback() {
    if (this.img) this.paint();
  }

  private paint() {
    const img = this.img;
    const note = this.note;
    if (!img || !note) return;
    const src = this.getAttribute("src") ?? "";
    img.alt = this.getAttribute("alt") ?? "";
    const fail = () => {
      img.hidden = true;
      note.hidden = false;
    };
    if (src === "") {
      img.removeAttribute("src");
      fail();
      return;
    }
    if (img.getAttribute("src") === src) return;
    img.hidden = false;
    note.hidden = true;
    img.onerror = fail;
    img.onload = () => {
      img.hidden = false;
      note.hidden = true;
    };
    img.src = src;
  }
}

if (!customElements.get("asset-thumb")) customElements.define("asset-thumb", AssetThumb);
