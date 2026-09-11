// 本文の飾りを 1 つずつ「使う → 下書き保存 → CMS から読み直して残っている」まで確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/rich-check.mjs
// 見る物:
//   1. 下線（underline の mark）
//   2. 表（table / tableRow / tableHeader / tableCell）と、行と列の足し引き
//   3. 画像の代替テキスト
//   4. 入れ子（表 in 表・上付き＋下付き）が作れない事と、CMS が断る事
//   4d.「+」と `/` の一覧から埋め込み（embed / linkCard）を入れられる
//   5. ツールバーが幅 1440 / 1024 / 768 で溢れない

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

function types(doc) {
  const out = new Set();
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.type) out.add(node.type);
    for (const mark of node.marks ?? []) out.add("mark:" + mark.type);
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
  const underline = page.locator('.tt-tool[title="下線"]');
  check((await underline.count()) === 1, "ツールバーに下線がある", `${await underline.count()} 個`);
  await underline.click();
  await page.waitForTimeout(400);
  check(types(JSON.parse((await docOf()) || "{}")).has("mark:underline"), "下線の mark が入る", (await docOf()).slice(0, 200));
  check(await underline.evaluate((el) => el.classList.contains("is-on")), "下線のボタンに印が付く", "付きません");
  await save("下線を入れた下書きが保存できる");

  // 2. 表
  await openNew(`rich-table ${marker}`);
  await page.keyboard.type("表のテスト");
  await page.keyboard.press("Enter");
  const table = page.locator('.tt-tool[title="表"]');
  check((await table.count()) === 1, "ツールバーに表がある", `${await table.count()} 個`);
  await table.click();
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  check((await page.locator(".tt-size-cell").count()) === 64, "大きさを升目で選べる", `${await page.locator(".tt-size-cell").count()} 升`);
  // 3 行 × 4 列（升目の 3 行目 4 列目）
  await page.locator(".tt-size-cell").nth(2 * 8 + 3).click();
  await page.waitForTimeout(700);
  const withTable = types(JSON.parse((await docOf()) || "{}"));
  check(withTable.has("table") && withTable.has("tableRow"), "表が入る", [...withTable].join(","));
  check(withTable.has("tableHeader"), "見出しの行が入る", [...withTable].join(","));
  check((await page.locator(".tt-body table").count()) === 1, "表が描かれる", "出ません");
  check((await page.locator(".tt-body table tr").count()) === 3, "選んだ行の数になる", `${await page.locator(".tt-body table tr").count()} 行`);
  check((await page.locator(".tt-body table tr").first().locator("th, td").count()) === 4, "選んだ列の数になる", "違います");

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

  // 寄せは列全体に効く
  await page.locator('.tt-tablebar-button[title="中央に寄せる"]').click();
  await page.waitForTimeout(500);
  const centered = JSON.parse((await docOf()) || "{}");
  const column = JSON.stringify(centered).split('"align":"center"').length - 1;
  check(column === 3, "寄せが列全体（3 行）に付く", `${column} 個`);

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
  await page.locator('.tt-tool[title="表"]').click();
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

  // 2c. コードブロックのファイル名
  await openNew(`rich-codefile ${marker}`);
  await page.keyboard.press("Enter");
  await page.locator('.tt-tool[title="コードブロック"]').click();
  await page.waitForTimeout(500);
  await page.keyboard.type("const a = 1;");
  await page.waitForTimeout(300);
  const file = page.locator(".tt-code-file").first();
  check((await file.count()) === 1, "コードブロックにファイル名の入力がある", `${await file.count()} 個`);
  await file.fill("src/main.ts");
  await page.locator("tiptap-editor .tt-body").click();
  await page.waitForTimeout(600);
  const withFile = JSON.parse((await docOf()) || "{}");
  const codeBlock = (withFile.content ?? []).find((node) => node.type === "codeBlock");
  check(codeBlock?.attrs?.fileName === "src/main.ts", "ファイル名が codeBlock の attrs に入る", JSON.stringify(codeBlock?.attrs ?? {}));
  // CMS が受けない形はその場で断る
  await file.fill('bad name<>"');
  await page.locator("tiptap-editor .tt-body").click();
  await page.waitForTimeout(500);
  check(await file.evaluate((el) => el.classList.contains("is-bad")), "受けない形のファイル名に印が付く", "付きません");
  const stillOk = (JSON.parse((await docOf()) || "{}").content ?? []).find((node) => node.type === "codeBlock");
  check(!("fileName" in (stillOk?.attrs ?? {})) || stillOk?.attrs?.fileName === null, "受けない形は doc に入らない", JSON.stringify(stillOk?.attrs ?? {}));
  await file.fill("src/main.ts");
  await page.locator("tiptap-editor .tt-body").click();
  await page.waitForTimeout(500);
  await save("ファイル名付きのコードブロックが保存できる");

  // 3. 画像の代替テキスト
  await openNew(`rich-caption ${marker}`);
  await page.locator('.tt-tool[aria-label="画像"]').click();
  await page.waitForTimeout(900);
  await page.locator(".fixed .grid button").nth(0).click();
  await page.getByRole("button", { name: /本文に挿入/ }).click();
  await page.waitForTimeout(700);
  const altBox = page.locator(".tt-image-alt").first();
  check((await page.locator(".tt-image.is-active .tt-image-caption").count()) === 1, "画像を選ぶとキャプションの figcaption が出る", `${await page.locator(".tt-image.is-active .tt-image-caption").count()} 個`);
  // 画像の帯は画像を押して node ごと選んだ時だけ。リンク / ALT / 縮小 / 配置 / 削除 の 5 つ（単独の画像。横に並べるは隣が画像の時だけ）
  // 画像を node ごと選ぶ（帯は node ごと選んだ時だけ出る）。
  const selectImage = async () => {
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = -1;
      editor.state.doc.descendants((node, pos) => { if (node.type.name === "image" && at < 0) at = pos; });
      editor.chain().focus().setNodeSelection(at).run();
    });
    await page.waitForTimeout(300);
  };
  await selectImage();
  const imageBar = await page.locator(".tt-image-bar .tt-image-tool").evaluateAll((els) => els.filter((el) => !el.hidden).map((el) => el.getAttribute("aria-label")));
  check(imageBar.join("/") === "リンク/代替テキスト/縮小/配置/削除", "画像の帯は リンク / ALT / 縮小 / 配置 / 削除 の順に並ぶ", imageBar.join("/"));
  // 配置を押すと帯が 左 / 中央 / 右 の 3 つに入れ替わり、1 つ押すと align を書いて元の帯に戻る
  await page.locator('.tt-image-tool[title="配置"]').first().click();
  await page.waitForTimeout(200);
  const alignBar = await page.locator(".tt-image-bar .tt-image-tool").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(alignBar.join("/") === "左に寄せる/中央に寄せる/右に寄せる", "配置を押すと帯が 左 / 中央 / 右 に入れ替わる", alignBar.join("/"));
  await page.locator('.tt-image-tool[title="左に寄せる"]').first().click();
  await page.waitForTimeout(400);
  const aligned = (JSON.parse((await docOf()) || "{}").content ?? []).find((node) => node.type === "image");
  check(aligned?.attrs?.align === "left", "左に寄せる で align=left が入る", JSON.stringify(aligned?.attrs ?? {}));
  check((await page.locator('.tt-image-tool[title="配置"]').count()) === 1, "配置を選ぶと元の帯に戻る");
  await page.locator('.tt-image-tool[title="配置"]').first().click();
  await page.locator('.tt-image-tool[title="中央に寄せる"]').first().click();
  await page.waitForTimeout(300);
  // キャプションは中身（text + marks）。打つと content に入り、attrs.caption は出ない
  await page.locator(".tt-image.is-active .tt-image-caption").click();
  await page.keyboard.type("きゃぷしょん");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  const withCaption = (JSON.parse((await docOf()) || "{}").content ?? []).find((node) => node.type === "image");
  check(withCaption?.content?.[0]?.text === "きゃぷしょん" && withCaption?.attrs?.caption === undefined, "キャプションが image の content に入る（attrs.caption は出ない）", JSON.stringify(withCaption ?? {}));
  check((JSON.parse((await docOf()) || "{}").content ?? []).filter((node) => node.type === "image").length === 1 && withCaption?.content?.length === 1, "キャプションの中の Enter は何もしない", JSON.stringify(withCaption?.content ?? []));
  // キャプションの中では画像の帯は出ず、キャプションの上に 太字 / 打ち消し / リンク の 3 つ
  check(await page.locator(".tt-image .tt-image-bar").first().isHidden(), "キャプションを打っている間は画像の帯が出ない");
  const captionBar = await page.locator(".tt-bubble-caption button").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(captionBar.join("/") === "太字/打ち消し/リンク" && (await page.locator(".tt-bubble-caption").isVisible()), "キャプションの帯は 太字 / 打ち消し / リンク の 3 つ", captionBar.join("/"));
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
  check((await altBox.count()) === 1 && (await altBox.evaluate((el) => document.activeElement === el)), "ALT を押すと帯が代替テキストの欄に入れ替わり、焦点が入る", `${await altBox.count()} 個`);
  await altBox.fill("さんぷるの代替");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  const withAlt = JSON.parse((await docOf()) || "{}");
  const image = (withAlt.content ?? []).find((node) => node.type === "image");
  check(image?.attrs?.alt === "さんぷるの代替", "代替テキストが image の attrs に入る", JSON.stringify(image?.attrs ?? {}));
  check((await page.locator('.tt-image-tool[title="代替テキスト"]').count()) === 1, "適用の後は元の帯に戻る");

  const around = JSON.parse((await docOf()) || "{}");
  const kinds = (around.content ?? []).map((node) => node.type).join(" ");
  check(kinds.includes("paragraph image paragraph"), "画像の上下に行ができる", kinds);
  await save("代替テキスト付きの下書きが保存できる");

  // 4. 入れ子ができない
  await openNew(`rich-nest ${marker}`);
  await page.locator('.tt-tool[title="表"]').click();
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(1 * 8 + 1).click();
  await page.waitForTimeout(600);
  for (const title of ["引用", "コードブロック", "箇条書き", "区切り線"]) {
    await page.locator(".tt-body table th").first().click();
    await page.waitForTimeout(200);
    await page.locator(`.tt-tool[title="${title}"]`).click();
    await page.waitForTimeout(400);
    const inside = (JSON.parse((await docOf()) || "{}").content ?? [])
      .flatMap((node) => (node.type === "table" ? node.content ?? [] : []))
      .flatMap((row) => row.content ?? [])
      .flatMap((cell) => (cell.content ?? []).map((child) => child.type))
      .filter((kind) => kind !== "paragraph");
    check(inside.length === 0, `表のセルに「${title}」は入らない`, inside.join(" "));
  }
  // 表の中に表
  await page.locator(".tt-body table th").first().click();
  await page.locator('.tt-tool[title="表"]').click();
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(1 * 8 + 1).click();
  await page.waitForTimeout(600);
  const tables = (JSON.parse((await docOf()) || "{}").content ?? []).filter((node) => node.type === "table").length;
  const nested = JSON.stringify(JSON.parse((await docOf()) || "{}")).includes('"tableCell","content":[{"type":"table"');
  check(!nested, "表のセルに表は入らない", `表 ${tables} 個`);

  // 上付き＋下付き
  await openNew(`rich-raised ${marker}`);
  await page.locator('.tt-tool[title="上付き"]').click();
  await page.locator('.tt-tool[title="下付き"]').click();
  await page.keyboard.type("a");
  await page.waitForTimeout(400);
  const raised = (JSON.parse((await docOf()) || "{}").content?.[0]?.content?.[0]?.marks ?? []).map((m) => m.type);
  check(raised.length === 1 && raised[0] === "sub", "上付きと下付きは重ならない", raised.join("+"));
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

  // 4b. 入れた直後にカーソルが「続きを書ける所」に入る
  //
  // 中に文字を書けるブロックは中に、書けないブロック（カード・埋め込み）はその下の段落に。
  const focusOf = () =>
    page.evaluate(() => {
      const host = document.querySelector("tiptap-editor");
      const active = document.activeElement;
      const $from = host.editor.view.state.selection.$from;
      const names = [];
      for (let depth = $from.depth; depth > 0; depth -= 1) names.push($from.node(depth).type.name);
      return { dom: active ? String(active.className).split(" ")[0] : "", inside: names[0] ?? "doc", index: $from.index(0) };
    });

  // `$$` + Enter は、node view の中の TeX の欄に入る（ProseMirror の選択ではなく DOM の焦点）。
  await openNew(`rich-focus-math ${marker}`);
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  check((await focusOf()).dom === "tt-mathblock-src", "$$ の直後に TeX の欄へ入る", JSON.stringify(await focusOf()));
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);
  const mathDoc = JSON.parse((await docOf()) || "{}");
  check(JSON.stringify(mathDoc).includes('"tex":"E = mc^2"'), "$$ の直後に打った TeX が数式に入る", JSON.stringify(mathDoc).slice(0, 200));

  // 4c. 数式は「普段は組版だけ、箱のどこを押しても TeX、掴みで選ぶと削除の帯」
  //     （docs/design/richtext-math-ui.md）
  const mathSrc = page.locator(".tt-mathblock-src").first();
  const mathOut = page.locator(".tt-mathblock-out").first();
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.waitForTimeout(300);
  check(await mathSrc.isHidden(), "普段は TeX の欄が隠れている", "見えています");
  check((await page.locator(".tt-mathblock .katex").count()) > 0, "普段は組版された数式が出る", "出ません");
  check(
    await mathSrc.evaluate((el) => getComputedStyle(el).resize === "none"),
    "TeX の欄は掴んで伸ばせない",
    await mathSrc.evaluate((el) => getComputedStyle(el).resize)
  );

  await mathOut.click();
  await page.waitForTimeout(300);
  check(await mathSrc.isVisible(), "組版を押すと TeX の欄が開く", "開きません");
  check((await focusOf()).dom === "tt-mathblock-src", "組版を押すと TeX の欄へ焦点が入る", JSON.stringify(await focusOf()));

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

  // TeX の欄の 1 行目の ↑ で前の行へ出る（node view が鍵を食べても矢印は届く）
  await mathOut.click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-mathblock-src", "1 行目の ↑ で TeX の欄から前の行へ出る", JSON.stringify(await focusOf()));
  await mathOut.click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-mathblock-src", "最終行の ↓ で TeX の欄から次の行へ出る", JSON.stringify(await focusOf()));

  // ホバーの間だけ右上に削除が出る（案 B）
  const mathCorner = page.locator(".tt-mathblock .tt-block-corner").first();
  check((await mathCorner.count()) === 1, "数式の右上に削除が付く", `${await mathCorner.count()} 個`);
  check(
    (await mathCorner.getAttribute("aria-label")) === "削除",
    "ホバーの削除の aria-label は「削除」",
    String(await mathCorner.getAttribute("aria-label"))
  );
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
  // 右上の削除で数式が消え、段落に戻る
  await mathCorner.click();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "右上の削除で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  await page.mouse.move(5, 5);

  // もう一度 $$ で入れ直して、選んだ状態の帯を見る
  // （帯は箱の 76px 上に浮くので、数式が本文の先頭だと枠の外に出て押せない。1 行前に置く）
  await page.keyboard.type("すうしきのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(500);
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);
  // 欄の中の Esc は欄を閉じて数式を選んだ状態にする（上に削除だけの帯が出る）
  await page.keyboard.press("Escape");
  await page.waitForTimeout(400);
  check(
    (await page.locator(".tt-mathblock.ProseMirror-selectednode").count()) === 1,
    "欄の中の Esc で数式を選んだ状態になる",
    `${await page.locator(".tt-mathblock.ProseMirror-selectednode").count()} 個`
  );
  const mathBar = await page.locator(".tt-mathblock .tt-image-bar .tt-image-tool").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(mathBar.join("/") === "削除", "数式の帯は削除だけ", mathBar.join("/"));
  check(await mathSrc.isHidden(), "選んでいる間は TeX の欄を閉じる", "開いています");
  await page.locator(".tt-mathblock .tt-image-bar").first().scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await page.locator(".tt-mathblock .tt-image-tool").first().click();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "帯の削除で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  check(
    (JSON.parse((await docOf()) || "{}").content ?? []).every((node) => node.type === "paragraph"),
    "削除した所に段落が残る",
    JSON.stringify(JSON.parse((await docOf()) || "{}")).slice(0, 200)
  );

  // 空の TeX の欄で Backspace は段落に戻す
  await openNew(`rich-math-back ${marker}`);
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "空の TeX の欄の Backspace で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  await page.keyboard.type("もどった");
  await page.waitForTimeout(300);
  check(JSON.stringify(JSON.parse((await docOf()) || "{}")).includes("もどった"), "消した後は段落に続きが打てる", (await docOf()).slice(0, 200));

  // 引用の出典の欄も、端の欄でだけ引用の外へ出る（間は欄を渡る）
  const classOf = () => page.evaluate(() => String(document.activeElement?.className ?? ""));
  await openNew(`rich-quote-cite ${marker}`);
  await page.keyboard.type("いんようのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("> ひきよう");
  await page.waitForTimeout(400);
  await page.locator(".tt-quote-add").first().click();
  await page.waitForTimeout(300);
  check((await focusOf()).dom === "tt-quote-field", "「出典を追加」で出典の欄へ入る", JSON.stringify(await focusOf()));
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await classOf()).includes("tt-quote-cite-url"), "出典の ↓ は出典の URL の欄へ渡る", await classOf());
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check(
    (await classOf()).includes("tt-quote-cite") && !(await classOf()).includes("tt-quote-cite-url"),
    "出典の URL の ↑ は出典の欄へ戻る",
    await classOf()
  );
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-quote-field", "出典の ↑ で引用の外の行へ出る", JSON.stringify(await focusOf()));
  await page.locator(".tt-quote-add").first().click();
  await page.waitForTimeout(300);
  check((await focusOf()).dom === "tt-quote-field", "外へ出た後も「出典を追加」で欄へ入り直せる", JSON.stringify(await focusOf()));
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-quote-field", "出典の URL の ↓ で引用の外の行へ出る", JSON.stringify(await focusOf()));

  // コードブロックのファイル名の欄も、↑↓ で前後の行へ出る
  await openNew(`rich-code-file ${marker}`);
  await page.keyboard.type("こーどのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("```");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  await page.keyboard.type("let x = 1");
  await page.locator(".tt-code-file").first().click();
  await page.waitForTimeout(300);
  check((await focusOf()).dom === "tt-code-file", "ファイル名の欄へ入る", JSON.stringify(await focusOf()));
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-code-file", "ファイル名の欄の ↑ で前の行へ出る", JSON.stringify(await focusOf()));
  await page.locator(".tt-code-file").first().click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-code-file", "ファイル名の欄の ↓ で次の行へ出る", JSON.stringify(await focusOf()));

  // ``` + Enter はコードブロックの中。
  await openNew(`rich-focus-code ${marker}`);
  await page.keyboard.type("```");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  check((await focusOf()).inside === "codeBlock", "``` の直後にコードブロックの中へ入る", JSON.stringify(await focusOf()));

  // 引用は中の段落。
  await openNew(`rich-focus-quote ${marker}`);
  await page.keyboard.type("> ");
  await page.waitForTimeout(400);
  check((await focusOf()).inside === "paragraph", "> の直後に引用の中へ入る", JSON.stringify(await focusOf()));

  // 表は最初の升。
  await openNew(`rich-focus-table ${marker}`);
  await page.locator('.tt-tool[title="表"]').click();
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(2 * 8 + 2).click();
  await page.waitForTimeout(500);
  check((await focusOf()).inside === "paragraph", "表を入れた直後に升の中へ入る", JSON.stringify(await focusOf()));

  // URL 1 つを貼って作るカードは、中に書けないのでその下の段落へ。
  await openNew(`rich-focus-card ${marker}`);
  await page.evaluate(() => {
    const view = document.querySelector("tiptap-editor").editor.view;
    const data = new DataTransfer();
    data.setData("text/plain", "https://example.com/focus");
    view.dom.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  });
  await page.waitForTimeout(500);
  const cardAt = await focusOf();
  check(cardAt.inside === "paragraph" && cardAt.index === 1, "URL を貼った直後にカードの下の段落へ入る", JSON.stringify(cardAt));
  await page.keyboard.type("つづき");
  await page.waitForTimeout(400);
  const cardDoc = JSON.parse((await docOf()) || "{}");
  check(
    (cardDoc.content ?? []).map((node) => node.type).join(",") === "linkCard,paragraph" && JSON.stringify(cardDoc).includes("つづき"),
    "カードの後にそのまま続きが打てる",
    JSON.stringify(cardDoc).slice(0, 200)
  );

  // 4d.「+」と `/` の一覧から埋め込みを入れられる（URL の欄が出て、提供元で embed / linkCard に分かれる）
  for (const way of [
    { name: "「+」", bySlash: false, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", want: "embed" },
    { name: "「+」", bySlash: false, url: "https://example.com/rich-check", want: "linkCard" },
    { name: "`/`", bySlash: true, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", want: "embed" },
  ]) {
    await openNew(`rich-embed ${way.want} ${way.bySlash ? "slash" : "plus"} ${marker}`);
    if (way.bySlash) {
      await page.keyboard.type("/");
      await page.waitForTimeout(400);
    } else {
      await page.locator(".tt-plus").click();
      await page.waitForTimeout(300);
    }
    await page.locator(".tt-blocks-item", { hasText: "埋め込み" }).click();
    await page.waitForTimeout(400);
    const urlBox = page.locator(".tt-blocks-url");
    check((await urlBox.count()) === 1, `${way.name} の一覧の「埋め込み」で URL の欄が出る`, `${await urlBox.count()} 個`);
    if ((await urlBox.count()) !== 1) continue;
    await urlBox.fill(way.url);
    await urlBox.press("Enter");
    await page.waitForTimeout(800);
    const embedDoc = JSON.parse((await docOf()) || "{}");
    check(types(embedDoc).has(way.want), `${way.name} から ${way.url.includes("youtube") ? "YouTube" : "他"} の URL が ${way.want} になる`, JSON.stringify(embedDoc).slice(0, 200));
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
