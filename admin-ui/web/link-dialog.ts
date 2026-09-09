// リンクを張る時の選び方。
//
// **入力欄は 1 本。** 打った文字でコンテンツを探し、`http` や `mailto:` で始まったら
// 一番上に「この URL にリンクする」が出る。
//
// WhyNot: タブやラジオで「URL かコンテンツか」を先に選ばせない。押す前にどちらを
// したいか決めさせる事になる。**打った物で分かるなら聞かない。**
// （Contentful はプルダウン、Payload と Hygraph はラジオ。どれも 1 段深い）
//
// **コンテンツの検索はここでは投げない。** エディタは API を知らない（URL もヘッダも
// TypeScript の api.ts と Elm が持つ）。打った文字を `linksearch` の event で外に出し、
// 候補は `entries` の属性で返してもらう。

export type Candidate = { id: string; title: string; type: string; stage?: string };

// 選んだ物には**入れる文字**を添える。選択が空の時にこれを本文へ挿し込む
// （Notion / Craft / Zenn / Google ドキュメントが揃って、選んだ物の名前を入れる）。
export type LinkChoice = { href: string; label: string } | { entryId: string; label: string } | null;

type Args = {
  // 今かかっているリンク（無ければ null）
  current: { href?: string | null; entryId?: string | null } | null;
  onSearch: (query: string) => void;
  onDone: (choice: LinkChoice) => void;
};

// CMS が受ける href の形（`RichText.isSafeHref`）。これ以外は entry の検索に回す。
const URL_LIKE = /^(https?:\/\/|mailto:)/i;

export class LinkDialog {
  readonly dom: HTMLDivElement;
  private input: HTMLInputElement;
  private list: HTMLDivElement;
  private candidates: Candidate[] = [];
  private rows: LinkChoice[] = [];
  private at = 0;
  // 上下キーで動かした直後は、カーソルの下の候補に取られない。
  // WhyNot: mouseenter で拾わない。キーで動かすと面が動かなくてもカーソルの下の行が
  // 変わり、触っていないマウスに選択を奪われる。
  private byKey = false;
  private onDone: Args["onDone"];

  constructor(args: Args) {
    this.onDone = args.onDone;

    this.dom = document.createElement("div");
    this.dom.className = "tt-link";

    this.input = document.createElement("input");
    this.input.className = "tt-link-input";
    this.input.placeholder = "コンテンツを探す、または URL を貼る";
    this.input.setAttribute("aria-label", "リンク先");
    this.input.value = args.current?.href ?? "";

    this.list = document.createElement("div");
    this.list.className = "tt-link-list";

    this.dom.append(this.input, this.list);

    if (args.current) {
      const bottom = document.createElement("div");
      bottom.className = "tt-link-bottom";
      const drop = document.createElement("button");
      drop.type = "button";
      drop.className = "tt-link-drop";
      drop.textContent = "リンクを外す";
      drop.addEventListener("mousedown", (event) => {
        event.preventDefault();
        this.onDone(null);
      });
      bottom.appendChild(drop);
      this.dom.appendChild(bottom);
    }

    let typed = 0;
    this.input.addEventListener("input", () => {
      this.at = 0;
      this.paint();
      // 打つたびに投げると 1 文字ごとに飛ぶ。少し待つ。
      window.clearTimeout(typed);
      typed = window.setTimeout(() => args.onSearch(this.input.value), 200);
    });

    this.input.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        this.byKey = true;
        this.at = Math.min(this.at + 1, this.rows.length - 1);
        this.paint();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        this.byKey = true;
        this.at = Math.max(this.at - 1, 0);
        this.paint();
      } else if (event.key === "Enter") {
        event.preventDefault();
        const picked = this.rows[this.at];
        if (picked) this.onDone(picked);
      }
    });

    args.onSearch("");
    this.paint();
  }

  setCandidates(candidates: Candidate[]) {
    this.candidates = candidates;
    this.paint();
  }

  focusInput() {
    this.input.focus();
    this.input.select();
  }

  private paint() {
    const typed = this.input.value.trim();
    const urlRow: LinkChoice[] = URL_LIKE.test(typed) ? [{ href: typed, label: typed }] : [];
    this.rows = [...urlRow, ...this.candidates.map((candidate) => ({ entryId: candidate.id, label: candidate.title }))];
    this.at = Math.min(this.at, Math.max(this.rows.length - 1, 0));

    const children: HTMLElement[] = [];
    if (urlRow.length > 0) {
      children.push(this.row("この URL にリンクする", typed, 0, "is-url"));
    }
    this.candidates.forEach((candidate, index) => {
      children.push(this.row(candidate.title, candidate.type, urlRow.length + index, ""));
    });
    if (children.length === 0) {
      children.push(note(typed ? "見つかりません" : "コンテンツの名前か URL を入れてください"));
    }
    this.list.replaceChildren(...children);
    if (this.byKey) this.list.querySelector<HTMLElement>(".is-at")?.scrollIntoView({ block: "nearest" });
    this.byKey = false;
  }

  private row(title: string, side: string, index: number, extra: string): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tt-link-item" + (index === this.at ? " is-at" : "") + (extra ? " " + extra : "");
    const main = document.createElement("span");
    main.className = "tt-link-title";
    main.textContent = title;
    const aside = document.createElement("span");
    aside.className = "tt-link-kind";
    aside.textContent = side;
    button.append(main, aside);
    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      const picked = this.rows[index];
      if (picked) this.onDone(picked);
    });
    // 乗せた行を選択位置にもする（見た目だけ動いて Enter は別の物、を作らない）。
    button.addEventListener("mousemove", () => {
      if (this.at === index) return;
      this.at = index;
      this.paint();
    });
    return button;
  }
}

function note(text: string): HTMLElement {
  const span = document.createElement("span");
  span.className = "tt-link-note";
  span.textContent = text;
  return span;
}
