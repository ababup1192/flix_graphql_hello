// 直した 5 か所を 1440 / 1024 / 768 で測る。読むだけ（データは足さない）。
import { chromium } from "playwright";
import { open, overflow } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const widths = [1440, 1024, 768];
const out = "/tmp/ui-stress";

const browser = await chromium.launch();
for (const w of widths) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  console.log(`\n=== ${w} ===`);

  // 1. メディア: 総数と「もっと読む」
  await open(page, "/p/default/assets", 2500);
  const media = await page.evaluate(() => {
    const t = document.body.innerText;
    const m = t.match(/全 \d+ 枚のうち 1〜\d+ 枚/);
    const more = [...document.querySelectorAll("button")].find((b) =>
      b.textContent.includes("もっと読む"),
    );
    return { label: m ? m[0] : null, more: !!more, tiles: document.querySelectorAll("img").length };
  });
  console.log("media", JSON.stringify(media));
  await page.screenshot({ path: `${out}/fix-media-${w}.png` });
  if (media.more) {
    await page.evaluate(() =>
      [...document.querySelectorAll("button")]
        .find((b) => b.textContent.includes("もっと読む"))
        .click(),
    );
    await page.waitForTimeout(2000);
    const after = await page.evaluate(() => {
      const m = document.body.innerText.match(/全 \d+ 枚のうち 1〜\d+ 枚/);
      return m ? m[0] : null;
    });
    console.log("media after もっと読む:", after);
    await page.screenshot({ path: `${out}/fix-media-more-${w}.png`, fullPage: false });
  }

  // 2. API スキーマ: 40 フィールドで右の面が画面に残るか
  await open(page, `/p/default/c/${k.wide}/schema`, 2500);
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll("div")].filter((d) =>
      d.className.includes("cursor-pointer") && d.className.includes("grid"),
    );
    (rows[rows.length - 1] || rows[0])?.click();
  });
  await page.waitForTimeout(600);
  await page.evaluate(() => {
    const sc = [...document.querySelectorAll("div")].find(
      (d) => d.className.includes("overflow-auto") && d.scrollHeight > d.clientHeight + 200,
    );
    if (sc) sc.scrollTop = sc.scrollHeight;
    else window.scrollTo(0, document.body.scrollHeight);
  });
  await page.waitForTimeout(600);
  const panel = await page.evaluate(() => {
    const p = [...document.querySelectorAll("div")].find((d) =>
      d.className.includes("sticky") && d.className.includes("w-[380px]"),
    );
    if (!p) return { found: false };
    const r = p.getBoundingClientRect();
    return {
      found: true,
      top: Math.round(r.top),
      bottom: Math.round(r.bottom),
      inView: r.top < window.innerHeight && r.bottom > 0,
      h: Math.round(r.height),
    };
  });
  console.log("schema panel", JSON.stringify(panel));
  await page.screenshot({ path: `${out}/fix-schema-${w}.png` });

  // 3. ボード: カードの高さ・はみ出し・「他 N 件」
  await open(page, `/p/default/c/${k.art}/board`, 2500);
  const board = await page.evaluate(() => {
    const cards = [...document.querySelectorAll("[draggable=true]")];
    const heights = cards.map((c) => Math.round(c.getBoundingClientRect().height));
    let outOfCard = 0;
    for (const c of cards) {
      const cr = c.getBoundingClientRect();
      for (const el of c.querySelectorAll("*")) {
        const r = el.getBoundingClientRect();
        if (r.width && r.right - cr.right > 2) outOfCard++;
      }
    }
    return {
      cards: cards.length,
      maxH: Math.max(0, ...heights),
      outOfCard,
      moreTag: document.body.innerText.includes("他 "),
    };
  });
  console.log("board", JSON.stringify(board));
  await page.screenshot({ path: `${out}/fix-board-${w}.png` });

  // 4/5. 一覧: select の幅とタイトルの列の幅
  await open(page, `/p/default/c/${k.art}`, 2500);
  const list = await page.evaluate(() => {
    const sels = [...document.querySelectorAll("select")].map((s) =>
      Math.round(s.getBoundingClientRect().width),
    );
    const rows = [...document.querySelectorAll("div")].filter(
      (d) => d.className.includes("grid-cols-[minmax(0,1fr)") && d.className.includes("py-3"),
    );
    const first = rows[0];
    const cols = first
      ? [...first.children].map((c) => Math.round(c.getBoundingClientRect().width))
      : [];
    return { selects: sels, maxSelect: Math.max(0, ...sels), titleCol: cols[0] ?? null, cols };
  });
  console.log("list", JSON.stringify(list));
  await page.screenshot({ path: `${out}/fix-list-${w}.png` });

  // 参照の候補の select（Entries の絞り込み）
  const o = await overflow(page);
  console.log(`overflow docOver=${o.docOver}`, o.out.length ? JSON.stringify(o.out) : "");

  await page.close();
}
await browser.close();
