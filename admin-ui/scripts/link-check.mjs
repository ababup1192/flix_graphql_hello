// リンクの面を、実際の画面で確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/link-check.mjs
// 見る物:
//   1. 文字を選ばずに押して、コンテンツを選ぶ → 題が入り entryId のリンクになる
//   2. 文字を選ばずに押して、URL を貼る → URL が入り href のリンクになる
//   3. 文字を選んでから押す → 選んだ文字がリンクになる（今まで通り）
//   4. 面が、外のクリック・Escape・ボタン再押下で閉じ、面の中では閉じない
//   5. 候補にマウスを乗せると選択位置が移る
//   6. 長い題で行が折り返さず、種類が右に出る
//   7. 下書き保存 → CMS から読み直して link の mark が入っている

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
const linkButton = () => page.locator('.tt-tool[title="リンク"]');

// doc の全 text ノードの marks を平らに並べる。
function marksOf(doc) {
  const out = [];
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    for (const mark of node.marks ?? []) out.push({ mark, text: node.text ?? "" });
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

async function openDialog() {
  await linkButton().click();
  await page.waitForSelector(".tt-link", { timeout: 5000 });
  await page.waitForTimeout(400);
}

try {
  // 1. 選択なし + コンテンツ
  const title1 = `link-check-entry ${Date.now()}`;
  await openNew(title1);
  await page.keyboard.type("前の文。");
  await openDialog();
  await page.locator(".tt-link-input").fill("");
  await page.waitForTimeout(700);
  const rows = page.locator(".tt-link-item:not(.is-url)");
  check((await rows.count()) > 0, "コンテンツの候補が出る", `${await rows.count()} 件`);
  const pickedTitle = (await rows.first().locator(".tt-link-title").textContent()) ?? "";
  await rows.first().click();
  await page.waitForTimeout(600);
  const one = JSON.parse((await docOf()) || "{}");
  const entryMark = marksOf(one).find((found) => found.mark.type === "link" && found.mark.attrs?.entryId);
  check(Boolean(entryMark), "選択なしで entryId のリンクが入る", JSON.stringify(one).slice(0, 260));
  check(entryMark?.text === pickedTitle, "入る文字が候補の題と同じ", `入った "${entryMark?.text}" / 候補 "${pickedTitle}"`);
  await save("entryId のリンクを入れた下書きが保存できる");

  // 2. 選択なし + URL
  const title2 = `link-check-url ${Date.now()}`;
  await openNew(title2);
  await page.keyboard.type("前の文。");
  await openDialog();
  await page.locator(".tt-link-input").fill("https://example.com/a");
  await page.waitForTimeout(500);
  await page.locator(".tt-link-item.is-url").first().click();
  await page.waitForTimeout(600);
  const two = JSON.parse((await docOf()) || "{}");
  const hrefMark = marksOf(two).find((found) => found.mark.type === "link" && found.mark.attrs?.href);
  check(Boolean(hrefMark), "選択なしで href のリンクが入る", JSON.stringify(two).slice(0, 260));
  check(hrefMark?.text === "https://example.com/a", "入る文字が URL そのもの", `入った "${hrefMark?.text}"`);
  await save("href のリンクを入れた下書きが保存できる");

  // 3. 選択あり（今まで通り）
  const title3 = `link-check-selected ${Date.now()}`;
  await openNew(title3);
  await page.keyboard.type("ここにリンク");
  await page.waitForTimeout(400);
  for (let i = 0; i < 4; i += 1) {
    await page.keyboard.press("Shift+ArrowLeft");
    await page.waitForTimeout(60);
  }
  await openDialog();
  await page.locator(".tt-link-input").fill("https://example.com/b");
  await page.waitForTimeout(500);
  await page.locator(".tt-link-item.is-url").first().click();
  await page.waitForTimeout(600);
  const three = JSON.parse((await docOf()) || "{}");
  const onSelection = marksOf(three).find((found) => found.mark.type === "link");
  check(onSelection?.text === "にリンク", "選んだ文字だけがリンクになる", JSON.stringify(three).slice(0, 260));
  check(JSON.stringify(three).includes('"text":"ここ"'), "選ばなかった文字はリンクにならない", JSON.stringify(three).slice(0, 260));
  check(!JSON.stringify(three).includes("https://example.com/bここ"), "文字が二重に入らない", JSON.stringify(three).slice(0, 200));
  await save("選択ありのリンクを入れた下書きが保存できる");

  // 4. 閉じ方の 4 通り
  await openNew(`link-check-dismiss ${Date.now()}`);
  await openDialog();
  await page.locator(".tt-link-input").click();
  await page.waitForTimeout(200);
  check((await page.locator(".tt-link").count()) === 1, "面の中のクリックでは閉じない", "閉じました");
  // 面の外だが、画面が変わらない所を押す（左の帯を押すと別の画面に移ってしまう）。
  await page.locator("tiptap-editor .tt-body").click();
  await page.waitForTimeout(300);
  check((await page.locator(".tt-link").count()) === 0, "面の外のクリックで閉じる", "残っています");

  await openDialog();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  check((await page.locator(".tt-link").count()) === 0, "Escape で閉じる", "残っています");

  await openDialog();
  await linkButton().click();
  await page.waitForTimeout(300);
  check((await page.locator(".tt-link").count()) === 0, "ボタンの再押下で閉じる", "残っています");

  // 外のクリックで閉じた直後に、同じクリックで開き直らない
  await openDialog();
  await linkButton().click();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-link").count()) === 0, "閉じた直後に開き直らない", "開き直りました");

  // 5. ホバーで選択位置が移る
  await openDialog();
  await page.locator(".tt-link-input").fill("");
  await page.waitForTimeout(800);
  const all = page.locator(".tt-link-item");
  if ((await all.count()) >= 2) {
    await all.nth(1).hover();
    await page.waitForTimeout(200);
    const at = await page.evaluate(() =>
      Array.from(document.querySelectorAll(".tt-link-item")).findIndex((el) => el.classList.contains("is-at"))
    );
    check(at === 1, "乗せた候補が選択位置になる", `is-at は ${at} 番目`);
    const cursor = await all.nth(1).evaluate((el) => getComputedStyle(el).cursor);
    check(cursor === "pointer", "候補のカーソルが指になる", cursor);
  } else {
    fail("乗せた候補が選択位置になる", `候補が ${await all.count()} 件しかありません`);
  }

  // 6. URL とコンテンツの見分けが付く（5 の面を開いたまま使う）
  await page.locator(".tt-link-input").fill("");
  await page.waitForTimeout(900);
  check(
    (await page.locator(".tt-link-head").allTextContents()).join("/") === "コンテンツ",
    "コンテンツだけの時は見出しが 1 つ",
    (await page.locator(".tt-link-head").allTextContents()).join("/")
  );
  const shown = await page.locator(".tt-link-item").count();
  check(shown <= 8, "候補は 8 件までしか出さない", `${shown} 件`);
  const more = page.locator(".tt-link-more");
  if ((await more.count()) === 1) {
    await more.click();
    await page.waitForTimeout(300);
    check((await page.locator(".tt-link-item").count()) > shown, "もっと見るで残りが出る", `${shown} 件のまま`);
  } else {
    note("候補が 8 件以下なので「もっと見る」は出ない");
  }
  const stages = await page.evaluate(() =>
    Array.from(document.querySelectorAll(".tt-link-item:not(.is-url) .tt-link-kind")).map((el) => el.textContent ?? "")
  );
  check(
    stages.every((kind) => /（?(下書き|公開中)/.test(kind) || kind.includes("下書き") || kind.includes("公開中")),
    "候補に公開の状態が出る",
    JSON.stringify(stages).slice(0, 200)
  );
  check(
    (await page.locator(".tt-link-item:not(.is-url) .tt-link-icon svg").count()) > 0,
    "候補の行に印が出る"
  );

  await page.locator(".tt-link-input").fill("https://example.com/z");
  await page.waitForTimeout(700);
  check(
    (await page.locator(".tt-link-head").first().textContent()) === "URL",
    "URL を打つと URL の見出しが先頭に出る",
    (await page.locator(".tt-link-head").allTextContents()).join("/")
  );
  check(
    (await page.locator(".tt-link-item.is-url .tt-link-kind").textContent()) === "外部のページ",
    "URL の行は外部のページと出る",
    (await page.locator(".tt-link-item.is-url .tt-link-kind").textContent()) ?? ""
  );
  await page.locator(".tt-link-input").fill("");
  await page.waitForTimeout(800);

  // 6. 長い題で折り返さない・種類が出る
  for (const width of [1440, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(300);
    const heights = await page.evaluate(() =>
      Array.from(document.querySelectorAll(".tt-link-item")).map((el) => el.getBoundingClientRect().height)
    );
    check(heights.every((height) => height < 32), `幅 ${width} で候補が 1 行に収まる`, `高さ ${JSON.stringify(heights)}`);
    const kinds = await page.evaluate(() =>
      Array.from(document.querySelectorAll(".tt-link-item:not(.is-url) .tt-link-kind")).map((el) => el.textContent)
    );
    check(kinds.length > 0 && kinds.every((kind) => (kind ?? "").length > 0), `幅 ${width} で種類が出る`, JSON.stringify(kinds).slice(0, 200));
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.keyboard.press("Escape");

  // 7. CMS から読み直す
  const found = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query entries { entries(typeId: "5", first: 30) { nodes { id fields } } }` }),
  }).then((response) => response.json());
  const saved = JSON.stringify(found.data?.entries?.nodes ?? found);
  check(saved.includes('"type":"link"'), "CMS に link の mark が入っている", saved.slice(0, 300));
  check(saved.includes("entryId"), "CMS に entryId のリンクが入っている", saved.slice(0, 300));
  check(saved.includes("https://example.com/a"), "CMS に href のリンクが入っている", saved.slice(0, 300));
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
