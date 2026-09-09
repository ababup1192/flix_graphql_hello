// 画面を触って回り、詰まりと違和感を探す。
// smoke（決まった項目の検証）と違い、こちらは「気になる所を集める」ための物。

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const findings = [];
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

page.on("pageerror", (e) => findings.push(`JS の例外: ${String(e).slice(0, 160)}`));
page.on("console", (m) => {
  if (m.type() === "error") findings.push(`コンソール: ${m.text().slice(0, 160)}`);
});
page.on("response", (r) => {
  if (r.url().startsWith(base) && r.status() >= 400) findings.push(`${r.status()}: ${r.url().replace(base, "")}`);
});

const body = async () => ((await page.textContent("body")) ?? "").replace(/\s+/g, " ");
const say = (what) => findings.push(what);

async function visit(path, label) {
  await page.goto(base + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(900);
  const text = await body();
  if (text.trim().length < 40) say(`${label}: 画面がほぼ空（${path}）`);
  if (text.includes("読み込めませんでした")) say(`${label}: 読み込めませんでした（${path}）`);
  if (text.includes("この画面はまだ作っていません")) say(`${label}: 未実装のまま（${path}）`);
  return text;
}

// 全画面を一巡
await visit("/", "起動");
await visit("/projects", "プロジェクト選択");
await visit("/account", "自分");
await visit("/p/default/c/blogs", "コンテンツ一覧");
await visit("/p/default/c/blogs/board", "ボード");
await visit("/p/default/c/blogs/schema", "API スキーマ");
await visit("/p/default/c/blogs/settings", "API 設定");
await visit("/p/default/c/blogs/new", "新規作成");
await visit("/p/default/assets", "メディア");
await visit("/p/default/settings/members", "メンバー");
await visit("/p/default/settings/api-keys", "API キー");
await visit("/p/default/settings/project", "プロジェクト");
// API プレビューは専用のページではなく、一覧と 1 件から開く引き出し。
await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(700);
if ((await page.getByRole("button", { name: "API", exact: true }).count()) === 0) say("一覧に API プレビューのボタンが無い");
await visit("/p/default/c/authors", "著者の一覧");

// 無い物を開く
const missing = await visit("/p/default/c/nope", "無い API");
if (!missing.includes("ありません")) say("無い API を開いても『ありません』が出ない");
const missingEntry = await visit("/p/default/c/blogs/zzzz", "無いコンテンツ");
if (!missingEntry.includes("ありません")) say("無いコンテンツを開いても『ありません』が出ない");

// 一覧の絞り込みで 0 件にする
await page.goto(base + "/p/default/c/blogs?q=" + encodeURIComponent("そんな言葉は無い"), { waitUntil: "networkidle" });
await page.waitForTimeout(1200);
const empty = await body();
if (!empty.includes("ありません")) say(`0 件の時に何も言わない: ${empty.slice(0, 120)}`);

// エディタを開いて細かく見る
await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(800);
const firstEntry = page.locator("a").filter({ hasText: "Datalog" }).first();
if ((await firstEntry.count()) === 0) {
  say("一覧に「Datalog」のコンテンツが無い（見本データを入れ直してください）");
} else {
  await firstEntry.click();
  await page.waitForTimeout(2000);
}

const editor = await body();

if (editor.includes("undefined") || editor.includes("null")) say(`エディタに undefined / null が出ている: ${editor.slice(0, 160)}`);

// 保存の表示
const saveText = await page.locator("text=保存済み").count();
if (saveText === 0) say("エディタに保存の状態が出ていない");

// タグを 1 つ押して、下書き保存で書けるかを見る
const tag = page.locator("button", { hasText: "FLIX" }).first();
if ((await tag.count()) > 0) {
  await tag.click();
  const saveButton = page.getByRole("button", { name: "下書き保存" });
  if ((await saveButton.count()) === 0) say("下書き保存のボタンが無い");
  else {
    await saveButton.click();
    await page.waitForTimeout(1200);
    const after = await body();
    if (!after.includes("保存済み")) say(`下書き保存を押しても保存済みにならない: ${after.slice(0, 200)}`);
  }
}

// 空のタイトルで公開前の確認。**元に戻す**（探索が実データを壊さない）。
const keptTitle = await page.locator("input").first().inputValue();
await page.locator("input").first().fill("");
await page.waitForTimeout(3000);
const check = page.locator("button", { hasText: "公開前の確認" }).first();
if ((await check.count()) > 0) {
  await check.click();
  await page.waitForTimeout(1800);
  const report = await body();
  if (!report.includes("公開前の確認:") && !report.includes("公開できます")) {
    say(`必須が空でも確認の結果が出ない: ${report.slice(0, 200)}`);
  }
}

// 触った物を戻す
if (keptTitle) {
  await page.locator("input").first().fill(keptTitle);
  await page.waitForTimeout(3000);
}

// 幅を狭めて崩れを見る
for (const [width, label] of [[1024, "1024px"], [768, "768px"], [390, "390px"]]) {
  await page.setViewportSize({ width, height: 900 });
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  if (overflow > 8) say(`${label}: 横に ${overflow}px はみ出す`);
}

// 一覧の並び替えを変えて壊れないか
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(800);
const orderSelect = page.locator("select").nth(2);
if ((await orderSelect.count()) > 0) {
  const options = await orderSelect.locator("option").allTextContents();
  for (const option of options.slice(1, 4)) {
    await orderSelect.selectOption({ label: option });
    await page.waitForTimeout(1200);
    const listed = await body();
    if (listed.includes("読み込めませんでした")) say(`並び替え「${option}」で失敗する`);
    if (listed.includes("コンテンツがありません")) say(`並び替え「${option}」で 0 件になる`);
  }
}

// ボードのカードを掴んで落とす（確認が出るか）
await page.goto(base + "/p/default/c/blogs/board", { waitUntil: "networkidle" });
await page.waitForTimeout(1500);
const cards = page.locator('[draggable="true"]');
if ((await cards.count()) === 0) {
  say("ボードに掴めるカードが無い");
} else {
  // Playwright の dragTo は HTML5 のドラッグを起こさないので、event を直に投げる。
  await page.evaluate(() => {
    const card = document.querySelector('[draggable="true"]');
    const columns = document.querySelectorAll(".grid > div");
    const target = columns[columns.length - 1];
    if (!card || !target) return;
    const data = new DataTransfer();
    card.dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer: data }));
    target.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: data }));
    target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data }));
  });
  await page.waitForTimeout(900);
  const asked = await body();
  if (!asked.includes("公開しますか") && !asked.includes("公開を終えますか")) {
    say(`ボードで落としても確認が出ない: ${asked.slice(0, 160)}`);
  }
}

// ⌘K の focus とカーソル操作
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(800);
await page.keyboard.press("Meta+k");
await page.waitForTimeout(600);
const focused = await page.evaluate(() => document.activeElement?.id ?? "");
if (focused !== "palette-input") say(`検索を開いても入力に focus が来ない（今: ${focused || "無し"}）`);
await page.keyboard.type("Flix");
await page.waitForTimeout(1800);
const before = await page.evaluate(() =>
  Array.from(document.querySelectorAll(".max-h-80 button")).findIndex((b) => b.className.includes("bg-well"))
);
await page.keyboard.press("ArrowDown");
await page.waitForTimeout(300);
const after = await page.evaluate(() =>
  Array.from(document.querySelectorAll(".max-h-80 button")).findIndex((b) => b.className.includes("bg-well"))
);
if (after !== before + 1) say(`下キーで選択が動かない（${before} → ${after}）`);
await page.keyboard.press("Enter");
await page.waitForTimeout(1200);
if ((await page.locator("#palette-input").count()) > 0) say("Enter で検索が閉じない");

await browser.close();

if (findings.length === 0) {
  console.log("気になる所はありませんでした");
} else {
  console.log(`気になる所 ${findings.length} 件\n`);
  for (const item of [...new Set(findings)]) console.log("  - " + item);
}
