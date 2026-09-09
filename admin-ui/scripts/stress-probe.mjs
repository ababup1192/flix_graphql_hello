// 個別に触って確かめる。スクロール・チップ・⌘K・参照の候補・空の時。
import { chromium } from "playwright";
import { open, overflow } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const S = (n) => page.screenshot({ path: `/tmp/ui-stress/${n}.png` });

// ---- 40 フィールドの右のペインが付いてくるか ----
await open(page, "/p/default/c/zzstresswide/schema", 2000);
await page.evaluate(() => window.scrollTo(0, 1800));
await page.waitForTimeout(400);
const pane = await page.evaluate(() => {
  const el = [...document.querySelectorAll("div")].find((d) =>
    d.className.includes("w-[380px]") || (d.textContent || "").startsWith("フィールドの設定"),
  );
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { top: Math.round(r.top), sticky: getComputedStyle(el).position, scrollY: Math.round(window.scrollY) };
});
console.log("schema40 右のペイン:", JSON.stringify(pane));
await S("probe-schema40-scrolled");

// 40 番目のフィールドを押して、右のペインが見えるか
await page.evaluate(() => window.scrollTo(0, 100000));
await page.waitForTimeout(300);
const rows = page.locator("div.overflow-hidden.rounded-md button, div.overflow-hidden.rounded-md [role=button]");
await S("probe-schema40-bottom");

// ---- 変更履歴の版の数 ----
await open(page, `/p/default/c/zzstressart/${k.jaEntry}`, 2500);
const vers = await page.evaluate(() =>
  [...document.querySelectorAll("*")].filter((e) => /^v\d+$/.test((e.textContent || "").trim())).map((e) => e.textContent.trim()),
);
console.log("履歴に出た版:", vers.length, vers.slice(0, 3).join(","), "…", vers.slice(-2).join(","));

// ---- 絞り込みのチップを 10 個 ----
await open(page, "/p/default/c/blogs?where=" + encodeURIComponent(JSON.stringify([])), 1500);
await S("probe-filter-before");
for (let i = 0; i < 10; i += 1) {
  const b = page.getByRole("button", { name: "+ 絞り込み" });
  if (!(await b.count())) break;
  await b.click();
  await page.waitForTimeout(400);
}
await page.waitForTimeout(800);
console.log("チップ 10:", JSON.stringify(await overflow(page)).slice(0, 900));
await S("probe-filters-10");

// ---- ⌘K ----
await open(page, "/p/default/c/blogs", 1500);
await page.keyboard.press("Meta+k");
await page.waitForTimeout(600);
await page.keyboard.type("e", { delay: 40 });
await page.waitForTimeout(900);
const pal = await page.evaluate(() => {
  const fixed = [...document.querySelectorAll("div")].filter((d) => getComputedStyle(d).position === "fixed");
  return fixed.map((d) => {
    const r = d.getBoundingClientRect();
    return { h: Math.round(r.height), bottom: Math.round(r.bottom), cls: String(d.className).slice(0, 70) };
  }).slice(0, 8);
});
console.log("⌘K:", JSON.stringify(pal));
await S("probe-cmdk");
await page.keyboard.press("Escape");

// ---- 参照の候補（タグは 28 件） ----
await open(page, `/p/default/c/zzstressart/${k.jaEntry}`, 2500);
const sel = page.locator("select").last();
const opts = await sel.locator("option").allTextContents();
console.log("参照の候補:", opts.length, JSON.stringify(opts.slice(0, 2)));
const selW = await sel.evaluate((e) => Math.round(e.getBoundingClientRect().width));
console.log("参照の select の幅:", selW);
await S("probe-ref-select");

// ---- 空の時 ----
for (const [n, p] of [
  ["empty-entries", "/p/default/c/zzstressempty"],
  ["empty-schema", "/p/default/c/zzstressempty/schema"],
]) {
  await open(page, p, 1500);
  await S(`probe-${n}`);
}

await browser.close();
