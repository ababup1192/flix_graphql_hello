// 一覧の絞り込みと並び替えを実際に触って確かめる（読むだけ。画面のコードは触らない）。
import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const list = "/p/default/c/blogs";
let bad = 0;
const ok = (m) => console.log("  OK  " + m);
const ng = (m, d) => {
  bad += 1;
  console.log("  NG  " + m + " — " + String(d).replace(/\s+/g, " ").slice(0, 200));
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
const orders = [];
page.on("request", (r) => {
  const body = r.postData();
  if (body && body.includes("orderBy")) orders.push(body.slice(0, 400));
});

const text = async () => (await page.locator("body").innerText()).replace(/\s+/g, " ");
const totalOf = async () => Number(((await text()).match(/全 (\d+) 件/) ?? [0, 0])[1]);
const titles = async () => (await page.locator("a[href*='/c/blogs/'] span.truncate").allTextContents()).slice(0, 5);
const open = async (path, wait = 1600) => {
  await page.goto(base + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(wait);
};

// ---- 1. 絞り込みの言葉 ----
await open(list);
const all = await totalOf();
await page.getByRole("button", { name: "+ 絞り込み" }).click();
await page.waitForTimeout(700);

const labels = await page.locator("div.rounded-md.border select, div.rounded-md.border input").count();
const fieldSelect = page.locator("select").nth(2);
const opSelect = page.locator("select").nth(3);
const items = await fieldSelect.locator("option").allTextContents();
if (items.slice(-3).join("/") === "更新日時/作成日時/公開日時") ok(`項目の末尾に日時が並ぶ（全 ${items.length}）`);
else ng("項目の末尾に日時が並ぶ", items.slice(-3).join("/"));

const textOps = await opSelect.locator("option").allTextContents();
if (textOps.join("/") === "を含む/と一致する/で始まる/未入力") ok("テキストの演算子が文として読める");
else ng("テキストの演算子", textOps.join("/"));

// ラベルの見出しが無い
const body1 = await text();
if (!body1.includes("項目 条件 値") && !/条件\s*値/.test(body1)) ok("項目・条件・値のラベルを積まない");
else ng("ラベルを積まない", body1.slice(0, 160));
if (body1.includes("絞り込む") && body1.includes("閉じる") && !body1.includes("足す") && !body1.includes("やめる"))
  ok("ボタンが「絞り込む」「閉じる」になった");
else ng("ボタンの文言", `labels=${labels}`);

// ---- 2. テキストで実際に絞れる ----
await page.locator("input[aria-label='値']").fill("rich-table");
await page.waitForTimeout(300);
await page.getByRole("button", { name: "絞り込む" }).click();
await page.waitForTimeout(1600);
const narrowed = await totalOf();
if (narrowed > 0 && narrowed < all) ok(`テキストで絞れる（${narrowed} / ${all} 件）`);
else ng("テキストで絞れる", `${narrowed} / ${all}`);

const chip = (await page.locator("button.rounded-full").first().innerText()).replace(/\s+/g, " ").trim();
if (chip.startsWith("タイトル rich-table を含む")) ok(`チップが文として読める（${chip}）`);
else ng("チップが文として読める", chip);
if (page.url().includes("f=title")) ok("条件が URL に残る");
else ng("条件が URL に残る", page.url());

// ---- 3. 更新日時（where の直下）で絞れる ----
await page.getByRole("button", { name: "+ 絞り込み" }).click();
await page.waitForTimeout(500);
await page.locator("select").nth(2).selectOption({ label: "更新日時" });
await page.waitForTimeout(500);
const sysOps = await page.locator("select").nth(3).locator("option").allTextContents();
if (sysOps.join("/") === "以降/以前/より後/より前") ok("日時は前後で言う（等値と未入力は出さない）");
else ng("日時の演算子", sysOps.join("/"));

await page.locator("input[type=date]").fill("2030-01-01");
await page.waitForTimeout(200);
await page.getByRole("button", { name: "絞り込む" }).click();
await page.waitForTimeout(1600);
const future = await totalOf();
if (future === 0) ok("更新日時で絞れる（2030 年以降は 0 件）");
else ng("更新日時で絞れる", `${future} 件`);

await page.locator("button.rounded-full").nth(1).click();
await page.waitForTimeout(1500);
const back = await totalOf();
if (back === narrowed) ok("日時の条件だけ外せる");
else ng("日時の条件だけ外せる", `${back} != ${narrowed}`);

// 値が空なら押せない
await page.getByRole("button", { name: "+ 絞り込み" }).click();
await page.waitForTimeout(500);
if (await page.getByRole("button", { name: "絞り込む" }).isDisabled()) ok("値が空なら押せない");
else ng("値が空なら押せない", "押せてしまう");
await page.getByRole("button", { name: "閉じる" }).click();
await page.waitForTimeout(300);

// ---- 4. 見出しを押して並べ替え ----
await open(list);
orders.length = 0;
const head = (name) => page.locator("div.grid").first().getByRole("button", { name: new RegExp("^" + name) });
await head("タイトル").click();
await page.waitForTimeout(1600);
const asc = await titles();
if (orders.some((b) => b.includes("title") && b.includes("ASC"))) ok("見出しから title:ASC が飛ぶ");
else ng("見出しから title:ASC が飛ぶ", orders.slice(-1)[0] ?? "無し");
if (page.url().includes("order=title%3Aasc") || page.url().includes("order=title:asc")) ok("並び順が URL に乗る");
else ng("並び順が URL に乗る", page.url());

await head("タイトル").click();
await page.waitForTimeout(1600);
const desc = await titles();
if (desc.length && asc.length && desc[0] !== asc[0]) ok(`もう一度押すと逆順（${asc[0]} → ${desc[0]}）`);
else ng("もう一度押すと逆順", `${asc[0]} / ${desc[0]}`);

await page.reload({ waitUntil: "networkidle" });
await page.waitForTimeout(1800);
if ((await titles())[0] === desc[0]) ok("再読み込みしても並び順が残る");
else ng("再読み込みしても並び順が残る", `${(await titles())[0]} != ${desc[0]}`);

// 公開状態は押せない
if ((await page.locator("div.grid").first().getByRole("button", { name: /公開状態/ }).count()) === 0) ok("公開状態は押せない見出し");
else ng("公開状態は押せない見出し", "ボタンになっている");

// 並び替えのセレクトの言葉
await open(list);
const orderOpts = await page.locator("select").nth(1).locator("option").allTextContents();
if (orderOpts.slice(0, 6).join("/") === "更新日時の新しい順/更新日時の古い順/公開日時の新しい順/公開日時の古い順/作成日時の新しい順/作成日時の古い順")
  ok("並び替えの言葉が揃った");
else ng("並び替えの言葉", orderOpts.slice(0, 6).join("/"));
if (!orderOpts.some((o) => o.includes(" の"))) ok("項目名と固定文の間に空白が無い");
else ng("空白が無い", orderOpts.filter((o) => o.includes(" の")).join("/"));

// ---- 5. 狭い画面 ----
for (const w of [1440, 1024, 768]) {
  await page.setViewportSize({ width: w, height: 1000 });
  await open(list + "?f=" + encodeURIComponent("title:CONTAINS:rich,updatedAt:GTE:2020-01-01,createdAt:LTE:2030-01-01,publishedAt:GTE:2000-01-01,readMinutes:GTE:0"), 1800);
  await page.getByRole("button", { name: "+ 絞り込み" }).click();
  await page.waitForTimeout(800);
  const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  const chips = await page.locator("button.rounded-full").count();
  const headBtns = await page.locator("div.grid").first().getByRole("button").count();
  const wantBtns = w >= 1024 ? 2 : 1;
  if (over <= 0) ok(`幅 ${w}: 横にはみ出さない（チップ ${chips} 個）`);
  else ng(`幅 ${w}: 横にはみ出さない`, `${over}px はみ出し`);
  if (headBtns === wantBtns) ok(`幅 ${w}: 押せる見出しが ${headBtns} 個（畳まれた列は残さない）`);
  else ng(`幅 ${w}: 押せる見出し`, `${headBtns} 個（${wantBtns} を期待）`);
  await page.screenshot({ path: `/tmp/zzentries-${w}.png` });
}

// 50 文字の項目名
await page.setViewportSize({ width: 1440, height: 1000 });
await open("/p/default/c/zzstressart");
await page.getByRole("button", { name: "+ 絞り込み" }).click();
await page.waitForTimeout(800);
const over2 = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
if (over2 <= 0) ok("50 文字の項目名でもはみ出さない");
else ng("50 文字の項目名", `${over2}px はみ出し`);
await page.screenshot({ path: "/tmp/zzentries-long.png" });

console.log(bad === 0 ? "\n問題なし" : `\n${bad} 件の問題`);
await browser.close();
process.exit(bad === 0 ? 0 : 1);
