// 押せる物のカーソルと、メニューの閉じ方をブラウザで確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/pointer.mjs
// 見る物:
//   1. 主な画面で、リンクとボタンの上のカーソルが指（getComputedStyle().cursor）になるか
//   2. 単独のリンクが最初から下線を持っていないか（ホバーで引く決め）
//   3. 上のバーのメニューが、外を押すと閉じ、中の項目は動いてから閉じるか

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const problems = [];

function note(step, detail = "") {
  console.log(`  OK  ${step}${detail ? " — " + detail : ""}`);
}

function fail(step, detail) {
  problems.push(`  NG  ${step} — ${detail}`);
  console.log(`  NG  ${step} — ${detail}`);
}

const screens = [
  ["コンテンツ一覧", "/p/default/c/blogs"],
  ["ボード", "/p/default/c/blogs/board"],
  ["API スキーマ", "/p/default/c/blogs/schema"],
  ["API 設定", "/p/default/c/blogs/settings"],
  ["メディア", "/p/default/assets"],
  ["メンバー", "/p/default/settings/members"],
  ["API キー", "/p/default/settings/api-keys"],
  ["プロジェクト設定", "/p/default/settings/project"],
  ["アカウント", "/account"],
  ["プロジェクト選択", "/projects"],
];

// 画面の中の「押せる物」を集めて、カーソルと下線を見る。
// リッチテキストの本文（.tt-body）は文の中のリンクなので、下線が付いていて正しい。
const inspect = () => {
  const seen = [];
  const nodes = document.querySelectorAll("a, button, [role='button']");
  for (const el of nodes) {
    const box = el.getBoundingClientRect();
    if (box.width === 0 || box.height === 0) continue;
    if (el.tagName === "BUTTON" && el.disabled) continue;
    const style = getComputedStyle(el);
    seen.push({
      tag: el.tagName,
      label: (el.getAttribute("title") || el.textContent || "").trim().slice(0, 24),
      cursor: style.cursor,
      underline: style.textDecorationLine,
      inProse: !!el.closest(".tt-body"),
      href: el.getAttribute("href"),
    });
  }
  return seen;
};

const browser = await chromium.launch();
const page = await browser.newPage();
page.setDefaultTimeout(8000);

try {
  for (const [name, path] of screens) {
    await page.goto(base + path, { waitUntil: "networkidle" });
    await page.waitForTimeout(400);
    const found = await page.evaluate(inspect);
    if (found.length === 0) {
      fail(`${name}: 押せる物がある`, "1 つも見つかりません（画面が描けていない）");
      continue;
    }

    const arrows = found.filter((el) => el.cursor !== "pointer");
    if (arrows.length === 0) note(`${name}: 押せる物 ${found.length} 個すべてカーソルが指`);
    else fail(`${name}: カーソルが指`, arrows.map((el) => `${el.tag}「${el.label}」= ${el.cursor}`).join(" / "));

    const lined = found.filter((el) => !el.inProse && el.underline.includes("underline"));
    if (lined.length === 0) note(`${name}: 単独のリンクに最初から下線が無い`);
    else fail(`${name}: 下線はホバーで引く`, lined.map((el) => `${el.tag}「${el.label}」`).join(" / "));
  }

  // サイドバーの API の名前は 1 行に切り、title で全部読める
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(400);
  const sidebar = await page.evaluate(() =>
    [...document.querySelectorAll("span.truncate")]
      .filter((el) => el.getBoundingClientRect().width > 0)
      .map((el) => ({
        title: el.getAttribute("title") ?? "",
        text: el.textContent.trim(),
        lines: Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight || "20")),
        clipped: el.scrollWidth > el.clientWidth,
      }))
  );
  const wrapped = sidebar.filter((el) => el.lines > 1);
  if (sidebar.length > 0 && wrapped.length === 0) note(`名前が 1 行に収まる（${sidebar.length} 個）`);
  else fail("名前が 1 行に収まる", wrapped.map((el) => el.text).join(" / ") || "切る対象が 1 つもありません");

  const untitled = sidebar.filter((el) => el.clipped && el.title === "");
  if (untitled.length === 0) note("切れた名前は title で全部読める");
  else fail("切れた名前は title で全部読める", untitled.map((el) => el.text).join(" / "));

  // メニューの閉じ方
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(400);

  const openSelf = async () => {
    await page.getByRole("button", { name: /@/ }).first().click();
    await page.waitForTimeout(250);
  };
  const selfMenuOpen = () => page.getByRole("link", { name: "ログアウト" }).isVisible().catch(() => false);

  await openSelf();
  if (await selfMenuOpen()) note("自分のメニューが開く");
  else fail("自分のメニューが開く", "ログアウトが出ません");

  // 画面の何もない所を押す
  await page.mouse.click(640, 500);
  await page.waitForTimeout(250);
  if (!(await selfMenuOpen())) note("外を押すと自分のメニューが閉じる");
  else fail("外を押すと自分のメニューが閉じる", "開いたままです");

  // Escape でも閉じる
  await openSelf();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(250);
  if (!(await selfMenuOpen())) note("Escape で自分のメニューが閉じる");
  else fail("Escape で自分のメニューが閉じる", "開いたままです");

  // プロジェクトのメニュー
  const openProject = async () => {
    await page.getByRole("button", { name: /default|プロジェクト/ }).first().click();
    await page.waitForTimeout(250);
  };
  const projectMenuOpen = () => page.getByRole("link", { name: "すべてのプロジェクト" }).isVisible().catch(() => false);

  await openProject();
  if (await projectMenuOpen()) note("プロジェクトのメニューが開く（1 つでも出る）");
  else fail("プロジェクトのメニューが開く", "すべてのプロジェクトが出ません");

  if ((await page.getByText("今ここ").count()) === 0) note("「今ここ」が消えている");
  else fail("「今ここ」が消えている", "まだ出ています");

  await page.mouse.click(640, 500);
  await page.waitForTimeout(250);
  if (!(await projectMenuOpen())) note("外を押すとプロジェクトのメニューが閉じる");
  else fail("外を押すとプロジェクトのメニューが閉じる", "開いたままです");

  // 中の項目は動いてから閉じる
  await openProject();
  await page.getByRole("link", { name: "すべてのプロジェクト" }).click();
  await page.waitForTimeout(600);
  if (page.url().endsWith("/projects")) note("メニューの項目が動く");
  else fail("メニューの項目が動く", `今の URL: ${page.url()}`);
  if (!(await projectMenuOpen())) note("動いた後にメニューが閉じる");
  else fail("動いた後にメニューが閉じる", "開いたままです");

  // 今いる行は押せて、押すと閉じるだけ
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(400);
  await openProject();
  const here = page.getByRole("button", { name: "default" }).last();
  const hereCursor = await here.evaluate((el) => getComputedStyle(el).cursor);
  if (hereCursor === "pointer") note("今いる行も押せる（カーソルが指）");
  else fail("今いる行も押せる", `cursor = ${hereCursor}`);
  await here.click();
  await page.waitForTimeout(250);
  if (!(await projectMenuOpen())) note("今いる行を押すと閉じるだけ");
  else fail("今いる行を押すと閉じるだけ", "開いたままです");
} catch (error) {
  fail("最後まで回る", String(error).split("\n")[0]);
} finally {
  await browser.close();
}

console.log("");
if (problems.length === 0) {
  console.log("問題なし");
} else {
  console.log(`${problems.length} 件`);
  process.exit(1);
}
