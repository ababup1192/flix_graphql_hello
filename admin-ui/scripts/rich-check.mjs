// 本文の飾りを 1 つずつ「使う → 下書き保存 → CMS から読み直して残っている」まで確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/rich-check.mjs
// 見る物:
//
// **ここに置くのは 2 つだけ。**
//   - 遅い層: 位置・はみ出し・重なり・スクロール・ホバー・掴んで動かす・実際のメディア
//   - CMS 往復: 下書き保存して CMS から読み直す・CMS が断る
// doc と選択だけで決まる物は `dev/checks/*.test.ts`（vitest のブラウザモード）。
// 分け方は docs/design/editor-dom-parts.md の「検査の環境」。
//
// 見る物:
//   1. 飾りを使った下書きが保存できる（下線 / 表 / コード / 画像 / 上付き）
//   2. 表の帯と掴みの位置、掴んで列を入れ替える、幅を変えても枠を越えない
//   2c. コードの帯の位置、強調の帯と行番号の縦の揃い、色、帯の余白は打てない
//   3. 画像のキャプションから上下の行へ出る、実際のメディアを 2 枚続けて入れる
//   4. CMS が入れ子（表 in 表・引用 in 引用・上付き＋下付き）を断る
//   4c. 数式の箱のどこを押しても開く、ホバーの間だけ右上に削除が出る
//   4e. 引用の出典と gallery の「+」が枠に収まり、次のブロックに重ならない
//   4f. すべての帯とすべての浮く面（横断。部品は `web/ui.ts`）
//   4i. ツールバーが本文の枠の中で上に貼り付く
//   4n. リストの項目の 2 行目が 1 行目と揃う
//   5. ツールバーが幅 1440 / 1024 / 768 で溢れない
//   6. CMS から読み直して、飾りが残っている

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const cms = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const problems = [];
const steps = [];

const note = (step, detail = "") => steps.push(`  OK  ${step}${detail ? " — " + detail : ""}`);
const fail = (step, detail) => problems.push(`  NG  ${step} — ${detail}`);
const check = (ok, step, detail) => (ok ? note(step) : fail(step, detail));

// **型の id は seed のたびに変わる。** 焼き付けず apiId から引く。
const blogTypeId = await fetch(`${cms}/p/default/admin/graphql`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
  body: JSON.stringify({ query: `query { contentTypes { id apiId } }` }),
})
  .then((response) => response.json())
  .then((answer) => (answer.data?.contentTypes ?? []).find((type) => type.apiId === "blogs")?.id ?? "");

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

page.on("pageerror", (error) => problems.push(`  NG  JS の例外 — ${String(error).slice(0, 200)}`));
page.on("console", (message) => {
  if (message.type() === "error") problems.push(`  NG  コンソールのエラー — ${message.text().slice(0, 200)}`);
});

const docOf = () => page.evaluate(() => document.querySelector("tiptap-editor")?.getAttribute("doc") ?? "");

// doc の中の imageItem を順に。**画像の attrs もキャプションも imageItem が持つ**
// （`image` は入れ物で attrs を持たない。`docs/design/richtext-note-style.md` 3）。
function itemsOf(doc) {
  const out = [];
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.type === "imageItem") out.push(node);
    for (const child of node.content ?? []) walk(child);
  };
  walk(doc);
  return out;
}

async function openNew(title) {
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  await page.locator("input").first().fill(title);
  await page.locator("tiptap-editor .tt-body").click();
}

// 道具を 1 つ使う。**役割で 3 か所に分かれている**（`docs/design/toolbar-split-mock.html` の案 D）:
// ヘッダは押すだけで入る 6 個、浮く帯は文字に掛ける 6 個 +「…」、ブロックは「+」の一覧。
//
// 「…」と帯の物は**文字を選んでいないと押せない**（帯が出ない）。呼ぶ前に選んでおく。
const FOLDED = new Set(["下線", "蛍光ペン", "上付き", "下付き"]);
const IN_BUBBLE = new Set(["太字", "斜体", "打ち消し", "コード（文の中）", "数式（文の中）", "リンク"]);
// ヘッダから外した物と、「+」の一覧でのその名前。
// **画像は外さない**（書くたびに使うのでヘッダに残す）。「+」の一覧にも同じ口がある。
const IN_PLUS = { コードブロック: "コード", 区切り線: "区切り線", 表: "表", 引用: "引用", チェックリスト: "チェックリスト" };

async function use(title) {
  if (FOLDED.has(title)) {
    await page.locator(".tt-bubble .tt-more").click();
    await page.waitForTimeout(250);
    await page.locator(`.tt-more-item[data-more="${title}"]`).click();
    await page.waitForTimeout(250);
    return;
  }
  if (IN_BUBBLE.has(title)) {
    await page.locator(`.tt-bubble-tool[data-bubble="${title}"]`).click();
    await page.waitForTimeout(200);
    return;
  }
  if (IN_PLUS[title]) {
    await page.locator(".tt-plus").click();
    await page.waitForTimeout(250);
    await page.locator(".tt-blocks-item", { hasText: IN_PLUS[title] }).first().click();
    await page.waitForTimeout(300);
    return;
  }
  await page.locator(`.tt-tool[title="${title}"]`).click();
  await page.waitForTimeout(200);
}

async function save(step) {
  await page.getByRole("button", { name: "下書き保存" }).click();
  await page.waitForTimeout(1800);
  const body = (await page.textContent("body")) ?? "";
  check(body.includes("保存済み"), step, body.replace(/\s+/g, " ").slice(0, 240));
}

const marker = Date.now();

try {
  // 1. 下線
  await openNew(`rich-underline ${marker}`);
  await page.keyboard.type("したせん");
  for (let i = 0; i < 4; i += 1) await page.keyboard.press("Shift+ArrowLeft");
  await use("下線");
  await save("下線を入れた下書きが保存できる");

  // 2. 表
  await openNew(`rich-table ${marker}`);
  await page.keyboard.type("表のテスト");
  await page.keyboard.press("Enter");
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  // 3 行 × 4 列（升目の 3 行目 4 列目）
  await page.locator(".tt-size-cell").nth(2 * 8 + 3).click();
  await page.waitForTimeout(700);

  await page.locator(".tt-body table th, .tt-body table td").first().click();
  for (const letter of ["あ", "い", "う", "え"]) {
    await page.keyboard.type(letter);
    await page.keyboard.press("Tab");
  }
  await page.locator(".tt-body table th, .tt-body table td").first().click();
  await page.waitForTimeout(400);

  // 表の帯が表の上に出る
  const bar = page.locator(".tt-tablebar");
  check((await bar.count()) === 1, "表の上に帯が出る", `${await bar.count()} 個`);
  const barButtons = await page.locator(".tt-tablebar-button").evaluateAll((els) => els.map((el) => el.title));
  check(
    barButtons.join("/") === "大きさを変える/左に寄せる/中央に寄せる/右に寄せる/表を消す",
    "帯は大きさ・寄せ 3 つ・ゴミ箱の順に並ぶ",
    barButtons.join("/")
  );
  check((await page.locator(".tt-grip").count()) === 0, "古い掴みは出ない", `${await page.locator(".tt-grip").count()} 個`);
  const barAbove = await page.evaluate(() => {
    const box = document.querySelector(".tt-tablebar").getBoundingClientRect();
    const at = document.querySelector(".tt-body table").getBoundingClientRect();
    return Math.abs(box.left - at.left) < 4 && box.bottom <= at.top + 4;
  });
  check(barAbove, "帯が表の真上に付く", "ずれています");

  // 掴みは行と列の端に出る
  check((await page.locator(".tt-handle-col").count()) === 4, "列の掴みが列の数だけ出る", `${await page.locator(".tt-handle-col").count()} 個`);
  check((await page.locator(".tt-handle-row").count()) === 3, "行の掴みが行の数だけ出る（見出しも入る）", `${await page.locator(".tt-handle-row").count()} 個`);
  const fit = await page.evaluate(() => {
    const handles = Array.from(document.querySelectorAll(".tt-handle-col")).map((el) => el.getBoundingClientRect());
    const cells = Array.from(document.querySelectorAll(".tt-body table tr:first-child th, .tt-body table tr:first-child td")).map((el) => el.getBoundingClientRect());
    return handles.every((handle, i) => cells[i] && Math.abs(handle.width - cells[i].width) <= 3 && Math.abs(handle.left - cells[i].left) <= 3);
  });
  check(fit, "列の掴みが列の幅と揃う", "ずれています");


  // 掴んで列を入れ替える
  const headings = () => page.locator(".tt-body table tr:first-child th, .tt-body table tr:first-child td").allTextContents();
  const before = (await headings()).join("/");
  const spot = await page.evaluate(() => {
    const at = Array.from(document.querySelectorAll(".tt-handle-col")).map((el) => el.getBoundingClientRect());
    // 真ん中ちょうどでは入れ替わらない（跨いだ分だけ数えるため）。少し越える。
    return { from: { x: at[0].left + at[0].width / 2, y: at[0].top + 5 }, to: { x: at[1].left + at[1].width / 2 + 6, y: at[1].top + 5 } };
  });
  await page.mouse.move(spot.from.x, spot.from.y);
  await page.mouse.down();
  await page.mouse.move(spot.to.x, spot.to.y, { steps: 10 });
  check((await page.locator(".tt-move-line").count()) === 1, "動かしている間に落ちる境目の線が出る");
  await page.mouse.up();
  await page.waitForTimeout(500);
  const after = (await headings()).join("/");
  check(before === "あ/い/う/え" && after === "い/あ/う/え", "掴んで列を入れ替えられる", `${before} → ${after}`);
  await save("表を入れた下書きが保存できる");

  // 表から離れると消える
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.mouse.move(20, 20);
  await page.waitForTimeout(400);
  check((await page.locator(".tt-tablebar").count()) === 0, "表を触っていない時は帯が出ない", `${await page.locator(".tt-tablebar").count()} 個`);
  await page.locator(".tt-body table").hover();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-tablebar").count()) > 0, "表にマウスを乗せると帯が出る", "出ません");

  // 2b. 列が多い表・長い文字でも本文の枠からはみ出さない
  await openNew(`rich-table-wide ${marker}`);
  await page.keyboard.press("Enter");
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(1 * 8 + 7).click();
  await page.waitForTimeout(600);
  await page.locator(".tt-body table th, .tt-body table td").first().click();
  await page.keyboard.type("とても長い日本語のセルの中身です。折り返して読めるはずです。");
  await page.keyboard.press("Tab");
  await page.keyboard.type("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  await page.waitForTimeout(500);
  for (const width of [1440, 1024, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    const box = await page.evaluate(() => {
      const wrap = document.querySelector(".tt-body .tableWrapper");
      const body = document.querySelector(".tt-body");
      return {
        wrapRight: Math.round(wrap.getBoundingClientRect().right),
        bodyRight: Math.round(body.getBoundingClientRect().right),
        scrolls: wrap.scrollWidth > wrap.clientWidth,
        page: document.documentElement.scrollWidth,
        view: window.innerWidth,
      };
    });
    check(box.wrapRight <= box.bodyRight + 1, `幅 ${width} で表が本文の枠を越えない`, `表 ${box.wrapRight} > 本文 ${box.bodyRight}`);
    check(box.page <= box.view + 1, `幅 ${width} でページが横スクロールしない`, `${box.page} > ${box.view}`);
    note(`幅 ${width} の表`, box.scrolls ? "入れ物の中で横スクロール" : "枠に収まる");
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await save("列の多い表の下書きが保存できる");

  // 2c. コードブロックの下の帯（ファイル名 / 言語）と、左の行番号（強調行）
  await openNew(`rich-codefile ${marker}`);
  await page.keyboard.press("Enter");
  await use("コードブロック");
  await page.waitForTimeout(500);
  await page.keyboard.type("const a = 1;");
  await page.waitForSelector(".tt-code pre", { timeout: 5000 });
  await page.waitForTimeout(300);
  // 帯はコードの下（note と同じ）
  const barBox = await page.evaluate(() => {
    const pre = document.querySelector(".tt-code pre");
    const bar = document.querySelector(".tt-code-bar");
    return { pre: pre?.getBoundingClientRect().bottom ?? 0, bar: bar?.getBoundingClientRect().top ?? 0 };
  });
  check(barBox.bar >= barBox.pre - 1, "言語とファイル名の帯がコードの下にある", JSON.stringify(barBox));

  const file = page.locator(".tt-code-file").first();
  await file.fill("src/main.ts");
  await file.press("Enter");
  await page.waitForTimeout(600);

  await page.locator(".tt-code pre").first().click();
  await page.keyboard.press("End");
  await page.keyboard.type("\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;");
  await page.waitForTimeout(500);
  const numbers = page.locator(".tt-code-line");
  await numbers.nth(0).click();
  await page.waitForTimeout(400);
  await numbers.nth(2).click();
  await page.waitForTimeout(300);
  await numbers.nth(4).click({ modifiers: ["Shift"] });
  await page.waitForTimeout(400);
  await numbers.nth(0).click();
  await page.waitForTimeout(400);
  const linedUp = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(".tt-code-line")).map((el) => el.getBoundingClientRect());
    const bands = Array.from(document.querySelectorAll(".tt-code-band")).map((el) => el.getBoundingClientRect());
    return bands.length > 0 && bands.every((band) => rows.some((row) => Math.abs(row.top - band.top) < 2));
  });
  check(linedUp, "強調の帯が行番号と縦で揃う", "ずれています");

  // 言語は打って絞る。候補は正式名 + 別名 + 色の印、決めた後は整った名前
  const lang = page.locator(".tt-code-lang").first();
  await lang.click();
  await lang.fill("c++");
  await page.waitForTimeout(400);
  check(
    await page
      .locator(".tt-code-item .tt-code-mark")
      .first()
      .evaluate((el) => getComputedStyle(el).backgroundColor !== "rgba(0, 0, 0, 0)"),
    "候補の印に色が付く",
    "透明のままです"
  );
  await lang.press("Enter");
  await page.waitForTimeout(1200);
  check((await page.locator(".tt-body pre code span").count()) > 0, "選んだ言語で色が付く", "色の span がありません");

  // 帯の余白は打てない（contenteditable="false"）
  const barGap = await page.locator(".tt-code-bar").first().boundingBox();
  await page.mouse.click(barGap.x + barGap.width / 2, barGap.y + barGap.height / 2);
  await page.keyboard.type("aaaa");
  await page.waitForTimeout(400);
  check(
    !(await page.locator(".tt-code-bar").first().innerText()).includes("aaaa"),
    "帯の余白を押して打っても何も入らない",
    await page.locator(".tt-code-bar").first().innerText()
  );

  // 焦点が離れると帯だけが残る（placeholder は消える）
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.waitForTimeout(500);
  check(
    await page.locator(".tt-code").first().evaluate((el) => el.classList.contains("is-idle")),
    "焦点が外れると帯の placeholder が消える",
    "is-idle が付きません"
  );
  await save("ファイル名付きのコードブロックが保存できる");

  // 3. 画像の代替テキスト
  await openNew(`rich-caption ${marker}`);
  await use("画像");
  await page.waitForTimeout(900);
  await page.locator(".fixed .grid button").nth(0).click();
  await page.getByRole("button", { name: /本文に挿入/ }).click();
  await page.waitForTimeout(700);
  const altBox = page.locator(".tt-image-alt").first();
  // 画像の帯は画像を押して node ごと選んだ時だけ。リンク / ALT / 縮小 / 配置 / 削除 の 5 つ（単独の画像。横に並べるは隣が画像の時だけ）
  // 画像を node ごと選ぶ（帯は node ごと選んだ時だけ出る）。
  const selectImage = async () => {
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = -1;
      editor.state.doc.descendants((node, pos) => { if (node.type.name === "imageItem" && at < 0) at = pos; });
      editor.chain().focus().setNodeSelection(at).run();
    });
    await page.waitForTimeout(300);
  };
  await selectImage();
  // キャプションから上下の矢印で前後の行へ出られる
  for (const [key, where] of [["ArrowUp", "上"], ["ArrowDown", "下"]]) {
    await page.locator(".tt-image .tt-image-caption").first().click();
    await page.waitForTimeout(200);
    await page.keyboard.press(key);
    await page.waitForTimeout(300);
    const at = await page.evaluate(() => {
      const node = window.getSelection()?.anchorNode;
      const el = node?.nodeType === 3 ? node.parentElement : node;
      return el?.closest?.(".tt-body") ? (el.tagName ?? "") : "外";
    });
    check(at === "P", `キャプションから ${key} で${where}の行へ出る`, `カーソルの親 ${at}`);
    await page.keyboard.type(where);
    await page.waitForTimeout(200);
  }
  // 代替テキストは「ALT」を押すと帯が 欄 + 適用 + × に入れ替わり、Enter / 適用で書く
  await selectImage();
  await page.locator('.tt-image-tool[title="代替テキスト"]').first().click();
  await page.waitForTimeout(200);
  await altBox.fill("さんぷるの代替");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  await save("代替テキスト付きの下書きが保存できる");

  // 3b. 画像を 2 枚続けて入れる
  //
  // メディアの画面を開くとエディタが焦点を失い、疑似行（`web/block-edges.ts`）が消える。
  // 選択はその行の跡＝直前の画像のキャプションに戻るので、そこへ入れると「空の textblock は
  // 入れた物で置き換える」で 1 枚目の imageItem ごと置き換わっていた（1 枚目の assetId が消えた）。
  await openNew(`rich-two-images ${marker}`);
  const insertPicked = async (nth) => {
    await use("画像");
    await page.waitForTimeout(900);
    await page.locator(".fixed .grid button").nth(nth).click();
    await page.getByRole("button", { name: /本文に挿入/ }).click();
    await page.waitForTimeout(700);
  };
  await insertPicked(0);
  const firstId = itemsOf(JSON.parse((await docOf()) || "{}"))[0]?.attrs?.assetId ?? "";
  // 画像の下（本文の枠の余白）を押して行を足す。ここで押せる状態にしないとヘッダの画像は薄いまま。
  const body = await page.locator("tiptap-editor .tt-body").boundingBox();
  await page.mouse.click(body.x + body.width / 2, body.y + body.height - 6);
  await page.waitForTimeout(300);
  await insertPicked(1);
  const twoImages = JSON.parse((await docOf()) || "{}");
  const images = (twoImages.content ?? []).filter((node) => node.type === "image");
  const items = itemsOf(twoImages);
  check(images.length === 2, "画像を 2 枚続けて入れると image が 2 つになる", `${images.length} つ: ${JSON.stringify((twoImages.content ?? []).map((node) => node.type))}`);
  check(items[0]?.attrs?.assetId === firstId && firstId !== "", "2 枚目を入れても 1 枚目の assetId が残る", `${firstId} → ${JSON.stringify(items[0]?.attrs ?? {})}`);
  check(items.every((item) => item?.attrs?.assetId), "どの imageItem も assetId を持つ（既定値に潰れない）", JSON.stringify(items.map((item) => item?.attrs ?? {})));
  await save("画像 2 枚の下書きが保存できる");


  // 上付き＋下付き
  await openNew(`rich-raised ${marker}`);
  await page.keyboard.type("a");
  await page.keyboard.press("Shift+ArrowLeft");
  await page.waitForTimeout(300);
  await use("上付き");
  await use("下付き");
  await page.waitForTimeout(400);
  await save("上付きだけの下書きが保存できる");

  // CMS も入れ子を断る
  const send = (body) =>
    fetch(`${cms}/p/default/admin/graphql`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
      body: JSON.stringify(body),
    }).then((response) => response.json());
  const para = (text) => ({ type: "paragraph", content: [{ type: "text", text }] });
  const badDocs = {
    "表のセルの中の表": { type: "doc", content: [{ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [para("外"), { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [para("中")] }] }] }] }] }] }] },
    "引用の中の引用": { type: "doc", content: [{ type: "blockquote", content: [{ type: "blockquote", content: [para("中")] }] }] },
    "上付き＋下付き": { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "a", marks: [{ type: "sub" }, { type: "sup" }] }] }] },
  };
  for (const [name, doc] of Object.entries(badDocs)) {
    const answer = await send({
      query: `mutation m($fields: JSON!) { createEntry(typeId: "${blogTypeId}", fields: $fields) { id } }`,
      variables: { fields: { title: `nest ${marker} ${name}`, body: doc } },
    });
    const message = JSON.stringify(answer.errors ?? answer);
    check(message.includes("INVALID") || message.includes("入力"), `CMS が「${name}」を断る`, message.slice(0, 200));
  }

  // 数式を 1 つ置く（この先の位置と見た目の確認の相手）。
  await openNew(`rich-focus-math ${marker}`);
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);

  // 4c. 数式は「普段は組版だけ、箱のどこを押しても TeX、掴みで選ぶと削除の帯」
  //     （docs/design/richtext-math-ui.md）
  const mathSrc = page.locator(".tt-mathblock-src").first();
  const mathOut = page.locator(".tt-mathblock-out").first();
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.waitForTimeout(300);
  check(
    await mathSrc.evaluate((el) => getComputedStyle(el).resize === "none"),
    "TeX の欄は掴んで伸ばせない",
    await mathSrc.evaluate((el) => getComputedStyle(el).resize)
  );

  await mathOut.click();
  await page.waitForTimeout(300);

  // 組版の面の外（箱の左端の余白と、欄との隙間）を押しても同じように開く
  const mathBox = page.locator(".tt-mathblock").first();
  for (const [name, spot] of [["箱の左端", { x: 3, y: 0.5 }], ["箱の右端", { x: -3, y: 0.5 }]]) {
    await page.locator("tiptap-editor .tt-body p").first().click();
    await page.waitForTimeout(250);
    const box = await mathBox.boundingBox();
    await page.mouse.click(spot.x < 0 ? box.x + box.width + spot.x : box.x + spot.x, box.y + box.height * spot.y);
    await page.waitForTimeout(300);
    check(await mathSrc.isVisible(), `${name}を押しても TeX の欄が開く`, "開きません");
  }


  // ホバーの間だけ右上に削除が出る（案 B）
  const mathCorner = page.locator(".tt-mathblock .tt-block-corner").first();
  // 触っていない間は見えない（押した直後は指が箱の上に残っているので、先に外へ出す）
  await page.mouse.move(5, 5);
  await page.waitForTimeout(300);
  check(
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity === "0"),
    "触っていない間は右上の削除が見えない",
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity)
  );
  await mathBox.hover();
  await page.waitForTimeout(300);
  check(
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity === "1"),
    "ホバーすると右上の削除が出る",
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity)
  );
  await page.mouse.move(5, 5);


  // 引用の出典は箱の外の下の右。出典は引用の最後の子の quoteCite で、マークを掛けられる。
  // ↑ も ↓ も引用の外の行へ出る
  await openNew(`rich-quote-cite ${marker}`);
  await page.keyboard.type("いんようのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("> ひきよう");
  await page.waitForTimeout(400);
  const citeBelow = await page.evaluate(() => {
    const box = document.querySelector(".tt-quote blockquote").getBoundingClientRect();
    const row = document.querySelector(".tt-quote-cite-row").getBoundingClientRect();
    return row.top >= box.bottom - 1 && row.right >= box.right - 4;
  });
  check(citeBelow, "出典は箱の外の下、右に出る", "箱の中か左にあります");

  // 出典の行は node view の中（contentDOM の外）にある。引用の箱の高さにこの行が入らないと、
  // 次のブロックが行の上に乗る。次に来る 5 種で、行の下端が次のブロックの上端を越えない事を測る。
  for (const [kind, node] of Object.entries({
    数式: { type: "mathBlock", attrs: { tex: "\\sum_{i=1}^{n} \\frac{x_i^2}{\\sqrt{y_i}}" } },
    段落: { type: "paragraph", content: [{ type: "text", text: "次の段落" }] },
    画像: { type: "image", attrs: { src: "https://placehold.co/600x200.png", alt: "え" } },
    コード: { type: "codeBlock", attrs: { language: "javascript" }, content: [{ type: "text", text: "const a = 1;" }] },
    引用: {
      type: "blockquote",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "つぎのいんよう" }] },
        { type: "quoteCite", content: [{ type: "text", text: "つぎのしゅってん" }] },
      ],
    },
  })) {
    for (const cite of ["しゅってん", null]) {
      await page.evaluate(
        ([cite, node]) => {
          document.querySelector("tiptap-editor").editor.commands.setContent({
            type: "doc",
            content: [
              {
                type: "blockquote",
                content: [
                  { type: "paragraph", content: [{ type: "text", text: "ひきよう" }] },
                  ...(cite ? [{ type: "quoteCite", content: [{ type: "text", text: cite }] }] : []),
                ],
              },
              node,
              { type: "paragraph", content: [{ type: "text", text: "おわり" }] },
            ],
          });
        },
        [cite, node]
      );
      await page.waitForTimeout(500);
      const gap = await page.evaluate(() => {
        const quote = document.querySelector("tiptap-editor .tt-body .tt-quote");
        // 出典は箱に重ねて置くので、下端は出典（あれば）か、場所を空けている行で測る。
        const above = quote.querySelector("blockquote > cite") ?? quote.querySelector(".tt-quote-cite-row");
        return above.getBoundingClientRect().bottom - quote.nextElementSibling.getBoundingClientRect().top;
      });
      check(gap <= 0, `引用の出典の行が次のブロック（${kind}・出典${cite ? "あり" : "なし"}）に重ならない`, `${gap.toFixed(1)}px 食い込んでいます`);
    }
  }



  // 4e. 並べた画像（image > imageItem+）の下の空の段落でも「+」が本文の枠の中に出る。
  // キャプションの開閉や画像の読み込みは transaction を伴わずに高さを変えるので、
  // 一度測っただけの位置は取り残され、枠の外（下のフィールド）に出ていた。
  const galleryIds = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query { assets(first: 3) { edges { node { id } } } }` }),
  })
    .then((response) => response.json())
    .then((answer) => (answer.data?.assets?.edges ?? []).map((edge) => edge.node.id));
  if (galleryIds.length < 2) {
    fail("gallery を確かめるメディアがある", `${galleryIds.length} 個`);
  } else {
    await openNew(`rich-gallery ${marker}`);
    await page.evaluate((ids) => {
      document.querySelector("tiptap-editor").setAttribute(
        "doc",
        JSON.stringify({
          type: "doc",
          content: [
            { type: "paragraph", content: [{ type: "text", text: "まえがき" }] },
            { type: "image", content: ids.map((id) => ({ type: "imageItem", attrs: { assetId: id } })) },
            { type: "paragraph" },
          ],
        }),
      );
    }, galleryIds);
    await page.waitForTimeout(1200);
    // gallery の中のキャプションを開いてから末尾の空の段落へ移す（高さが変わる道）。
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = null;
      editor.state.doc.descendants((node, pos) => {
        if (at === null && node.type.name === "imageItem") at = pos + 1;
      });
      editor.commands.focus();
      editor.commands.setTextSelection(at);
    });
    await page.waitForTimeout(500);
    await page.evaluate(() => document.querySelector("tiptap-editor").editor.commands.focus("end"));
    await page.waitForTimeout(600);
    const plusAt = await page.evaluate(() => {
      const plus = document.querySelector(".tt-plus");
      const bodyBox = document.querySelector(".tt-body").getBoundingClientRect();
      const plusBox = plus.getBoundingClientRect();
      const editor = document.querySelector("tiptap-editor").editor;
      const paragraph = editor.view.nodeDOM(editor.state.selection.$from.before());
      const paraBox = paragraph?.getBoundingClientRect?.();
      return {
        hidden: plus.hidden,
        inside: plusBox.top >= bodyBox.top && plusBox.bottom <= bodyBox.bottom,
        off: paraBox ? Math.round(plusBox.top + plusBox.height / 2 - (paraBox.top + paraBox.height / 2)) : null,
      };
    });
    check(plusAt.hidden === false && plusAt.inside, "gallery の下の空の段落でも「+」が本文の枠の中に出る", JSON.stringify(plusAt));
    check(Math.abs(plusAt.off ?? 999) <= 4, "「+」が空の段落の高さに並ぶ", `${plusAt.off} px ずれています`);

    // 中の画像が gallery の枠からはみ出さない。
    const outs = await page.evaluate(() => {
      const box = document.querySelector(".tt-gallery").getBoundingClientRect();
      return [...document.querySelectorAll(".tt-gallery-grid .tt-image")].map((one) => Math.round(one.getBoundingClientRect().right - box.right));
    });
    check(outs.every((out) => out <= 0), "gallery の中の画像が枠に収まる", `はみ出し ${JSON.stringify(outs)}`);

    // 列を選ぶ帯は無く、列は枚数から決まる（2 枚なら 2 列、3 枚以上は 3 列で折り返す）。
    check((await page.locator(".tt-gallery-bar").count()) === 0, "列を選ぶ帯が無い");
    const columns = await page.evaluate(() => getComputedStyle(document.querySelector(".tt-gallery-grid")).gridTemplateColumns.split(" ").length);
    const wantColumns = Math.min(galleryIds.length, 3);
    check(columns === wantColumns, `${galleryIds.length} 枚の gallery は ${wantColumns} 列になる`, `${columns} 列`);

  }

  // 4f. 帯と浮く面の横断の確認（部品は `web/ui.ts`。`docs/design/editor-dom-parts.md`）。
  // ブロックごとに書かず、**すべての帯とすべての面**を同じ物差しで見る。
  await openNew(`rich-parts ${marker}`);
  const filler = Array.from({ length: 6 }, (_ignore, index) => ({ type: "paragraph", content: [{ type: "text", text: `うめ ${index}` }] }));
  const setDoc = (content) =>
    page.evaluate((body) => document.querySelector("tiptap-editor").editor.commands.setContent({ type: "doc", content: body }), content);

  await setDoc([
    ...filler,
    { type: "codeBlock", attrs: { language: "javascript" }, content: [{ type: "text", text: "const a = 1" }] },
    { type: "mathBlock", attrs: { tex: "E = mc^2" } },
    { type: "linkCard", attrs: { url: "https://example.com/parts" } },
    { type: "embed", attrs: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" } },
    { type: "paragraph" },
  ]);
  await page.waitForTimeout(1200);

  // 帯の余白（中の欄とボタンに当たらない点）を探す。
  const gapOf = (selector) =>
    page.evaluate((one) => {
      const bar = document.querySelector(one);
      if (!bar || bar.hidden) return null;
      const box = bar.getBoundingClientRect();
      if (box.height === 0) return null;
      for (let x = box.left + 3; x < box.right - 3; x += 2) {
        const y = box.top + box.height / 2;
        if (document.elementFromPoint(x, y) === bar) return { x, y };
      }
      return null;
    }, selector);
  const pickNode = (type) =>
    page.evaluate((name) => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = -1;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name === name && at < 0) at = pos;
      });
      if (at >= 0) editor.commands.setNodeSelection(at);
    }, type);

  // どの帯の余白を押しても、キャレットが出ず、打っても何も入らない。
  for (const bar of [
    { at: ".tt-code-bar", name: "コード", node: null },
    { at: ".tt-mathblock .tt-block-bar", name: "数式", node: "mathBlock" },
    { at: ".tt-link-card .tt-block-bar", name: "リンクカード", node: "linkCard" },
  ]) {
    if (bar.node) await pickNode(bar.node);
    await page.waitForTimeout(400);
    const gap = await gapOf(bar.at);
    if (!gap) {
      fail(`${bar.name} の帯の余白がある`, bar.at);
      continue;
    }
    await page.mouse.click(gap.x, gap.y);
    await page.waitForTimeout(200);
    const caret = await page.evaluate((one) => {
      const bar = document.querySelector(one);
      const picked = window.getSelection();
      return !!picked && picked.rangeCount > 0 && !!picked.anchorNode && bar.contains(picked.anchorNode);
    }, bar.at);
    check(!caret, `${bar.name} の帯の余白を押してもキャレットが出ない`, "出ました");
    await page.keyboard.type("zzzz");
    await page.waitForTimeout(300);
    const inBar = (await page.textContent(bar.at)) ?? "";
    check(!inBar.includes("zzzz"), `${bar.name} の帯に文字が入らない`, inBar.slice(0, 40));
    check(!(await docOf()).includes("zzzz"), `${bar.name} の帯の余白を押して打っても doc に入らない`, "入りました");
    await page.keyboard.press("Escape");
  }

  // 浮く面は、画面からも本文の枠からも出ない。
  const popOf = (selector) =>
    page.evaluate((one) => {
      const el = document.querySelector(one);
      if (!el || el.hidden) return null;
      const box = el.getBoundingClientRect();
      const body = document.querySelector("tiptap-editor .tt-body").getBoundingClientRect();
      return {
        height: Math.round(box.height),
        inScreen: box.top >= 0 && box.bottom <= window.innerHeight && box.left >= 0 && box.right <= window.innerWidth,
        inBody: box.bottom <= body.bottom + 1,
      };
    }, selector);

  await page.locator(".tt-code-lang").first().click();
  await page.waitForTimeout(400);
  const langPop = await popOf(".tt-code-pop");
  check(!!langPop && langPop.inScreen && langPop.inBody, "言語の候補が画面と本文の枠に収まる", JSON.stringify(langPop));

  // 本文を送っても、面は基準の欄に付いたまま（画面座標で置いていたら離れる）。
  const offsetOf = () =>
    page.evaluate(() => {
      const pop = document.querySelector(".tt-code-pop").getBoundingClientRect();
      const box = document.querySelector(".tt-code-lang").getBoundingClientRect();
      return Math.round(pop.top - box.bottom);
    });
  const offsetBefore = await offsetOf();
  await page.mouse.wheel(0, 150);
  await page.waitForTimeout(400);
  const offsetAfter = await offsetOf();
  check(Math.abs(offsetBefore - offsetAfter) <= 1, "本文を送っても言語の候補が欄に付いたまま", `${offsetBefore} → ${offsetAfter}`);
  await page.keyboard.press("Escape");
  await page.mouse.wheel(0, -300);
  await page.waitForTimeout(300);

  // 本文の一番下の段落で開く面（ブロックの一覧・埋め込みの URL）も枠から出ない。
  await page.locator("tiptap-editor .tt-body > p").last().click();
  await page.waitForTimeout(500);
  await page.locator(".tt-plus").click();
  await page.waitForTimeout(400);
  const listPop = await popOf(".tt-blocks");
  check(!!listPop && listPop.inScreen && listPop.inBody, "一番下の段落のブロックの一覧が画面と本文の枠に収まる", JSON.stringify(listPop));
  await page.locator(".tt-blocks-item", { hasText: "埋め込み" }).click();
  await page.waitForTimeout(400);
  const urlPop = await popOf(".tt-blocks");
  check(!!urlPop && urlPop.inScreen && urlPop.inBody, "一番下の段落の埋め込みの URL が画面と本文の枠に収まる", JSON.stringify(urlPop));
  await page.keyboard.press("Escape");


  // 4i. ツールバーが本文の枠の中で上に貼り付く（本文が長くても道具が押せる）。
  await openNew(`rich-sticky ${marker}`);
  await page.evaluate(() => {
    const body = Array.from({ length: 40 }, (_ignore, index) => ({ type: "paragraph", content: [{ type: "text", text: `長い本文の ${index} 行目です。` }] }));
    body.splice(20, 0, { type: "codeBlock", attrs: { language: null }, content: [{ type: "text", text: "const a = 1" }] });
    document.querySelector("tiptap-editor").editor.commands.setContent({ type: "doc", content: [...body, { type: "paragraph" }] });
  });
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 900);
  await page.waitForTimeout(600);
  const stuck = await page.evaluate(() => {
    const box = document.querySelector("tiptap-editor .tt-bar").getBoundingClientRect();
    const head = document.querySelector(".sticky.top-0")?.getBoundingClientRect();
    return {
      visible: box.top >= 0 && box.bottom <= window.innerHeight,
      underHead: head ? box.top < head.bottom - 1 : false,
      top: Math.round(box.top),
    };
  });
  check(stuck.visible, "本文を長くして送ってもツールバーが見える", JSON.stringify(stuck));
  check(!stuck.underHead, "ツールバーが上の帯（下書き保存 / 公開）の下に潜らない", JSON.stringify(stuck));

  // 浮く面は貼り付いた帯の上に出る（`--z-dropdown` > `--z-sticky`）。
  await page.locator("tiptap-editor .tt-code-lang").first().click();
  await page.waitForTimeout(500);
  const onTop = await page.evaluate(() => {
    const pop = document.querySelector(".tt-code-pop");
    if (!pop || pop.hidden) return null;
    const box = pop.getBoundingClientRect();
    const hit = document.elementFromPoint((box.left + box.right) / 2, box.top + 6);
    return { inPop: !!hit && !!hit.closest(".tt-code-pop") };
  });
  check(!!onTop && onTop.inPop, "言語の候補が貼り付いたツールバーの下に隠れない", JSON.stringify(onTop));
  await page.keyboard.press("Escape");

  // 「広げて書く」でも道具は残る（送るのは本文の方）。
  const bigger = page.locator('[title="広げて書く"], [aria-label="広げて書く"]').first();
  if ((await bigger.count()) > 0) {
    await bigger.click();
    await page.waitForTimeout(800);
    await page.evaluate(() => document.querySelector("tiptap-editor .tt-mount").scrollBy(0, 900));
    await page.waitForTimeout(500);
    const big = await page.evaluate(() => {
      const box = document.querySelector("tiptap-editor .tt-bar").getBoundingClientRect();
      const mount = document.querySelector("tiptap-editor .tt-mount").getBoundingClientRect();
      return { visible: box.top >= 0 && box.bottom <= window.innerHeight, aboveBody: box.bottom <= mount.top + 1 };
    });
    check(big.visible && big.aboveBody, "広げて書くでも送ったあとツールバーが見える", JSON.stringify(big));
    await page.keyboard.press("Escape");
    await page.waitForTimeout(400);
  }


  // 4n. リストの項目の中で Shift+Enter した 2 行目が、1 行目の文字の左端と揃う。
  // 3 種（チェックリスト・箇条書き・番号付き）で、段落の行の箱の左端を Range から測る。
  await openNew(`list wrap ${marker}`);
  await use("チェックリスト");
  await page.keyboard.type("チェックの一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(300);
  await use("箇条書き");
  await page.keyboard.type("箇条書きの一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(300);
  await use("番号付き");
  await page.keyboard.type("番号の一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.waitForTimeout(400);
  const listLines = await page.evaluate(() =>
    [...document.querySelectorAll("tiptap-editor .tt-body li")]
      .map((li) => {
        const paragraph = li.querySelector("p");
        if (!paragraph) return null;
        const range = document.createRange();
        range.selectNodeContents(paragraph);
        return {
          kind: li.closest('ul[data-type="taskList"]') ? "チェックリスト" : li.closest("ol") ? "番号付き" : "箇条書き",
          lefts: [...range.getClientRects()].filter((box) => box.width > 0).map((box) => Math.round(box.left * 100) / 100),
        };
      })
      .filter((row) => row !== null)
  );
  check(listLines.length === 3, "3 種のリストが 1 項目ずつ出来る", JSON.stringify(listLines));
  for (const row of listLines) {
    const [first, second] = row.lefts;
    check(
      row.lefts.length === 2 && Math.abs(first - second) < 0.5,
      `${row.kind}の項目の 2 行目が 1 行目と揃う`,
      `行の左端 ${JSON.stringify(row.lefts)}`
    );
  }

  // 5. ツールバーの幅
  for (const width of [1440, 1024, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    const bar = await page.locator(".tt-bar").first().evaluate((el) => ({
      height: el.getBoundingClientRect().height,
      scroll: el.scrollWidth,
      client: el.clientWidth,
      buttons: el.querySelectorAll(".tt-tool").length,
    }));
    note(`幅 ${width} のツールバー`, `高さ ${Math.round(bar.height)} / 中身 ${bar.scroll} ≦ 枠 ${bar.client} / ボタン ${bar.buttons} 個`);
    check(bar.scroll <= bar.client + 1, `幅 ${width} でツールバーが横に溢れない`, `中身 ${bar.scroll} > 枠 ${bar.client}`);
    const outside = await page.evaluate(() => {
      const bar = document.querySelector(".tt-bar");
      const box = bar.getBoundingClientRect();
      return Array.from(bar.children)
        .filter((el) => el.getBoundingClientRect().right > box.right + 1)
        .map((el) => el.getAttribute("title") ?? el.className);
    });
    check(outside.length === 0, `幅 ${width} でボタンが枠からはみ出さない`, JSON.stringify(outside));
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // 6. CMS から読み直す
  const found = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query entries { entries(typeId: "${blogTypeId}", first: 40) { nodes { id fields } } }` }),
  }).then((response) => response.json());
  const saved = JSON.stringify(found.data?.entries?.nodes ?? found);
  check(saved.includes('"type":"underline"'), "CMS に underline の mark が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"table"'), "CMS に table が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"tableHeader"'), "CMS に tableHeader が入っている", saved.slice(0, 300));
  check(saved.includes("さんぷるの代替"), "CMS に画像の代替テキストが入っている", saved.slice(0, 300));
  check(saved.includes("src/main.ts"), "CMS に codeBlock の fileName が入っている", saved.slice(0, 300));
} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 400));
} finally {
  await browser.close();
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.log("\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`\n通りました（${steps.length} 件）。`);
