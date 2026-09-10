// リンクを張る時の選び方。
//
// **入力欄は 1 本。** 打った文字でコンテンツを探し、`http` や `mailto:` で始まったら
// 一番上に「この URL にリンクする」が出る。**行は「URL」と「コンテンツ」に分けて
// 見出しを付ける**（1 本の欄でも、どちらを選ぼうとしているかは目で分かるようにする）。
//
// WhyNot: タブやラジオで「URL かコンテンツか」を先に選ばせない。押す前にどちらを
// したいか決めさせる事になり、一番多い「URL を貼る」が 2 手になる。Contentful は
// セレクト、Payload はラジオで先に聞くが、あちらは URL / Entry / Asset / Resource と
// 4 通り以上ある。ここは 2 通りなので、打った物で分かる（WordPress と同じ）。
//
// **コンテンツの検索はここでは投げない。** エディタは API を知らない（URL もヘッダも
// TypeScript の api.ts と Elm が持つ）。打った文字を `linksearch` の event で外に出し、
// 候補は `entries` の属性で返してもらう。

export type Candidate = { id: string; title: string; type: string; stage?: string };

// 一度に出す候補の数。**型ごとに 5 件ずつ来る**ので、型が 8 つあると 40 件並ぶ。
const SHOWN = 8;

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
  // 「もっと見る」を押したか。押すまでは上位 SHOWN 件だけ出す。
  private all = false;
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
      this.all = false;
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
    const shown = this.all ? this.candidates : this.candidates.slice(0, SHOWN);
    this.rows = [...urlRow, ...shown.map((candidate) => ({ entryId: candidate.id, label: candidate.title }))];
    this.at = Math.min(this.at, Math.max(this.rows.length - 1, 0));

    const children: HTMLElement[] = [];
    if (urlRow.length > 0) {
      children.push(head("URL"));
      children.push(this.row(typed, "外部のページ", 0, "is-url"));
    }
    if (shown.length > 0) {
      children.push(head("コンテンツ"));
      shown.forEach((candidate, index) => {
        children.push(this.row(candidate.title, `${candidate.type} · ${stageLabel(candidate.stage)}`, urlRow.length + index, ""));
      });
    }
    if (!this.all && this.candidates.length > SHOWN) {
      children.push(this.more(this.candidates.length - SHOWN));
    }
    if (children.length === 0) {
      children.push(note(typed ? "見つかりません" : "コンテンツの名前か URL を入れてください"));
    }
    this.list.replaceChildren(...children);
    if (this.byKey) this.list.querySelector<HTMLElement>(".is-at")?.scrollIntoView({ block: "nearest" });
    this.byKey = false;
  }

  private more(rest: number): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tt-link-more";
    button.textContent = `もっと見る（あと ${rest} 件）`;
    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      this.all = true;
      this.paint();
    });
    return button;
  }

  private row(title: string, side: string, index: number, extra: string): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tt-link-item" + (index === this.at ? " is-at" : "") + (extra ? " " + extra : "");
    const icon = document.createElement("span");
    icon.className = "tt-link-icon";
    icon.innerHTML = extra === "is-url" ? ICON_OUT : ICON_ENTRY;
    const main = document.createElement("span");
    main.className = "tt-link-title";
    main.textContent = title;
    const aside = document.createElement("span");
    aside.className = "tt-link-kind";
    aside.textContent = side;
    button.append(icon, main, aside);
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

// 外部は「外へ出る矢印」、コンテンツは「紙」。行の頭で 2 種類を見分ける。
const ICON_OUT =
  '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17 17 7"/><path d="M9 7h8v8"/></svg>';
const ICON_ENTRY =
  '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/></svg>';

function stageLabel(stage: string | undefined): string {
  if (stage === "PUBLISHED") return "公開中";
  if (stage === "CHANGED") return "公開中 · 下書きあり";
  return "下書き";
}

function head(text: string): HTMLElement {
  const span = document.createElement("span");
  span.className = "tt-link-head";
  span.textContent = text;
  return span;
}

function note(text: string): HTMLElement {
  const span = document.createElement("span");
  span.className = "tt-link-note";
  span.textContent = text;
  return span;
}
