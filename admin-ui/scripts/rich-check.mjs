// 本文の飾りを 1 つずつ「使う → 下書き保存 → CMS から読み直して残っている」まで確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/rich-check.mjs
// 見る物:
//   1. 下線（underline の mark）
//   2. 表（table / tableRow / tableHeader / tableCell）と、行と列の足し引き
//   3. 画像のキャプションと代替テキスト
//   4. ツールバーが幅 1440 / 1024 / 768 で溢れない

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const cms = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const problems = [];
const steps = [];

const note = (step, detail = "") => steps.push(`  OK  ${step}${detail ? " — " + detail : ""}`);
const fail = (step, detail) => problems.push(`  NG  ${step} — ${detail}`);
const check = (ok, step, detail) => (ok ? note(step) : fail(step, detail));

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
  await page.keyboard.type("あ");
  await page.waitForTimeout(400);

  // 掴みが表の上に出る
  const colGrips = page.locator(".tt-grip-col");
  const rowGrips = page.locator(".tt-grip-row");
  check((await colGrips.count()) === 4, "列の掴みが列の数だけ出る", `${await colGrips.count()} 個`);
  check((await rowGrips.count()) === 3, "行の掴みが行の数だけ出る", `${await rowGrips.count()} 個`);
  // 掴みが表の上に重なっている
  const overlap = await page.evaluate(() => {
    const grip = document.querySelector(".tt-grip-col").getBoundingClientRect();
    const cell = document.querySelector(".tt-body table th, .tt-body table td").getBoundingClientRect();
    return Math.abs(grip.left - cell.left) < 4 && grip.bottom <= cell.top + 4;
  });
  check(overlap, "列の掴みが列の真上に付く", "ずれています");
  // 見えているのは細い線。太い棒にしない
  const thin = await page.evaluate(() => {
    const col = document.querySelector(".tt-grip-col");
    const row = document.querySelector(".tt-grip-row");
    const seen = (el, side) => el.getBoundingClientRect()[side] - parseFloat(getComputedStyle(el)[`border${side === "height" ? "Top" : "Left"}Width`]) * 2;
    return {
      colSeen: col.getBoundingClientRect().height - parseFloat(getComputedStyle(col).borderTopWidth) * 2,
      rowSeen: row.getBoundingClientRect().width - parseFloat(getComputedStyle(row).borderLeftWidth) * 2,
      colHit: col.getBoundingClientRect().height,
      rowHit: row.getBoundingClientRect().width,
      opacity: Number(getComputedStyle(col).opacity),
    };
  });
  check(thin.colSeen <= 6 && thin.rowSeen <= 6, "掴みの見えている線は細い", `列 ${thin.colSeen}px / 行 ${thin.rowSeen}px`);
  check(thin.colHit >= 8 && thin.rowHit >= 8, "掴みの当たり判定は広い", `列 ${thin.colHit}px / 行 ${thin.rowHit}px`);
  check(thin.opacity < 1, "掴みは薄く出る", String(thin.opacity));
  // 列の幅とぴったり合う
  const fit = await page.evaluate(() => {
    const grips = Array.from(document.querySelectorAll(".tt-grip-col")).map((el) => el.getBoundingClientRect());
    const cells = Array.from(document.querySelectorAll(".tt-body table tr:first-child th, .tt-body table tr:first-child td")).map((el) => el.getBoundingClientRect());
    return grips.every((grip, i) => cells[i] && Math.abs(grip.width - cells[i].width) <= 3 && Math.abs(grip.left - cells[i].left) <= 3);
  });
  check(fit, "列の掴みが列の幅と揃う", "ずれています");

  // 掴みから行を足す
  const beforeRows = await page.locator(".tt-body table tr").count();
  await rowGrips.nth(1).click();
  await page.waitForSelector(".tt-menu", { timeout: 4000 });
  const menuTexts = await page.locator(".tt-menu-item").allTextContents();
  check(menuTexts.join("/") === "上に行を足す/下に行を足す/この行を消す", "行の掴みは行の操作だけを出す", menuTexts.join("/"));
  await page.getByRole("button", { name: "下に行を足す" }).click();
  await page.waitForTimeout(600);
  check((await page.locator(".tt-body table tr").count()) === beforeRows + 1, "掴みから行を足せる", `${beforeRows} → ${await page.locator(".tt-body table tr").count()}`);

  // 掴みから列を足す
  const beforeCols = await page.locator(".tt-body table tr").first().locator("th, td").count();
  await colGrips.nth(0).click();
  await page.waitForSelector(".tt-menu", { timeout: 4000 });
  const colTexts = await page.locator(".tt-menu-item").allTextContents();
  check(colTexts.join("/") === "左に列を足す/右に列を足す/この列を消す", "列の掴みは列の操作だけを出す", colTexts.join("/"));
  await page.getByRole("button", { name: "右に列を足す" }).click();
  await page.waitForTimeout(600);
  check(
    (await page.locator(".tt-body table tr").first().locator("th, td").count()) === beforeCols + 1,
    "掴みから列を足せる",
    `${beforeCols} → ${await page.locator(".tt-body table tr").first().locator("th, td").count()}`
  );
  await save("表を入れた下書きが保存できる");

  // 表から離れると消える
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.mouse.move(20, 20);
  await page.waitForTimeout(400);
  check((await page.locator(".tt-grip").count()) === 0, "表を触っていない時は掴みが出ない", `${await page.locator(".tt-grip").count()} 個`);
  await page.locator(".tt-body table").hover();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-grip").count()) > 0, "表にマウスを乗せると掴みが出る", "出ません");

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

  // 3. 画像のキャプションと代替テキスト
  await openNew(`rich-caption ${marker}`);
  await page.locator('.tt-tool[aria-label="画像"]').click();
  await page.waitForTimeout(900);
  await page.locator(".fixed .grid button").nth(0).click();
  await page.getByRole("button", { name: /本文に入れる/ }).click();
  await page.waitForTimeout(700);
  const captionBox = page.locator(".tt-image-caption").first();
  const altBox = page.locator(".tt-image-alt").first();
  check((await captionBox.count()) === 1, "画像にキャプションの入力がある", `${await captionBox.count()} 個`);
  check((await altBox.count()) === 1, "画像に代替テキストの入力がある", `${await altBox.count()} 個`);
  await captionBox.fill("さんぷるの説明");
  await altBox.click();
  await altBox.fill("さんぷるの代替");
  await page.locator("tiptap-editor .tt-body").click();
  await page.waitForTimeout(600);
  const withCaption = JSON.parse((await docOf()) || "{}");
  const image = (withCaption.content ?? []).find((node) => node.type === "image");
  check(image?.attrs?.caption === "さんぷるの説明", "キャプションが image の attrs に入る", JSON.stringify(image?.attrs ?? {}));
  check(image?.attrs?.alt === "さんぷるの代替", "代替テキストが image の attrs に入る", JSON.stringify(image?.attrs ?? {}));
  await save("キャプション付きの下書きが保存できる");

  // 4. ツールバーの幅
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

  // 5. CMS から読み直す
  const found = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query entries { entries(typeId: "5", first: 40) { nodes { id fields } } }` }),
  }).then((response) => response.json());
  const saved = JSON.stringify(found.data?.entries?.nodes ?? found);
  check(saved.includes('"type":"underline"'), "CMS に underline の mark が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"table"'), "CMS に table が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"tableHeader"'), "CMS に tableHeader が入っている", saved.slice(0, 300));
  check(saved.includes("さんぷるの説明"), "CMS に画像のキャプションが入っている", saved.slice(0, 300));
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
