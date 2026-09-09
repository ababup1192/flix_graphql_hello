// 絞り込みチップ・スクロール容器・⌘K・プロジェクト 10 個（差し替え）・メディア。
import { chromium } from "playwright";
import { open, overflow, widths } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const browser = await chromium.launch();
const S = (page, n) => page.screenshot({ path: `/tmp/ui-stress/${n}.png` });

// ---- 絞り込みのチップ 10 個（1 つは長い値） ----
const conds = [
  "title:CONTAINS:" + encodeURIComponent("とても長い絞り込みの値ですとても長い絞り込みの値です"),
  "slug:CONTAINS:abc",
  "excerpt:CONTAINS:def",
  "readMinutes:GTE:3",
  "featured:EQ:true",
  "publishAt:GTE:2026-01-01",
  "updatedAt:GTE:2026-01-01",
  "createdAt:LTE:2026-12-31",
  "publishedAt:GTE:2026-02-01",
  "title:NOT_CONTAINS:zzz",
].join(",");

for (const w of widths) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, `/p/default/c/blogs?f=${encodeURIComponent(conds)}`, 2000);
  const chips = await page.evaluate(() =>
    [...document.querySelectorAll("body *")].filter((e) => /×$/.test((e.textContent || "").trim()) && e.children.length <= 2).length,
  );
  console.log(`${w} filters10 chips=${chips} ${JSON.stringify(await overflow(page)).slice(0, 700)}`);
  await S(page, `probe-filters10-${w}`);
  await page.close();
}

// ---- 中の scroll 容器を探して schema40 を下まで送る ----
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/c/zzstresswide/schema", 2000);
  const sc = await page.evaluate(() => {
    const found = [];
    for (const el of [document.documentElement, ...document.querySelectorAll("body *")]) {
      if (el.scrollHeight > el.clientHeight + 40 && el.clientHeight > 200) {
        const st = getComputedStyle(el);
        if (["auto", "scroll"].includes(st.overflowY)) {
          found.push({ tag: el.tagName, cls: String(el.className).slice(0, 60), sh: el.scrollHeight, ch: el.clientHeight });
          el.dataset.scroller = "1";
        }
      }
    }
    return found;
  });
  console.log("scroll 容器:", JSON.stringify(sc));
  await page.evaluate(() => {
    const el = document.querySelector("[data-scroller]");
    if (el) el.scrollTop = 100000;
  });
  await page.waitForTimeout(500);
  await S(page, "probe-schema40-bottom2");
  const paneTop = await page.evaluate(() => {
    const el = [...document.querySelectorAll("div")].find((d) => (d.textContent || "").startsWith("フィールドの設定"));
    return el ? { top: Math.round(el.getBoundingClientRect().top), pos: getComputedStyle(el.parentElement).position } : null;
  });
  console.log("schema40 右のペイン（下まで送った後）:", JSON.stringify(paneTop));
  await page.close();
}

// ---- ⌘K の候補が多い時 ----
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/c/blogs", 1500);
  await page.keyboard.press("Meta+k");
  await page.waitForTimeout(500);
  await page.keyboard.type("と", { delay: 40 });
  await page.waitForTimeout(1200);
  const box = await page.evaluate(() => {
    const ov = [...document.querySelectorAll("div")].find((d) => String(d.className).includes("fixed inset-0"));
    if (!ov) return null;
    const panel = ov.firstElementChild;
    const r = panel.getBoundingClientRect();
    const lists = [...panel.querySelectorAll("*")].filter((e) => {
      const s = getComputedStyle(e);
      return ["auto", "scroll"].includes(s.overflowY);
    }).map((e) => ({ cls: String(e.className).slice(0, 50), h: Math.round(e.getBoundingClientRect().height), sh: e.scrollHeight }));
    return { panelBottom: Math.round(r.bottom), panelH: Math.round(r.height), vh: window.innerHeight, lists };
  });
  console.log("⌘K 候補が多い時:", JSON.stringify(box));
  await S(page, "probe-cmdk-many");
  await page.close();
}

// ---- プロジェクト 10 個（account API の返事を差し替えて見るだけ） ----
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const long = "とても長いプロジェクトの名前です".repeat(4);
  await page.route("**/account/graphql", async (route) => {
    const res = await route.fetch();
    let body = await res.text();
    try {
      const j = JSON.parse(body);
      const ps = j?.data?.me?.projects;
      if (Array.isArray(ps) && ps.length) {
        const proto = ps[0];
        const more = [];
        for (let i = 0; i < 10; i += 1) {
          const c = JSON.parse(JSON.stringify(proto));
          const p = c.project ?? c;
          p.id = `zzfake${i}`;
          p.slug = `zz-fake-${i}`;
          p.name = i < 2 ? long : `zz にせ プロジェクト ${i}`;
          more.push(c);
        }
        j.data.me.projects = [...ps, ...more];
        body = JSON.stringify(j);
      }
    } catch (e) {}
    route.fulfill({ response: res, body });
  });
  await open(page, "/projects", 2000);
  console.log("projects 画面:", JSON.stringify(await overflow(page)).slice(0, 700));
  await S(page, "probe-projects10");
  await open(page, "/p/default/c/blogs", 2000);
  await page.locator("button", { hasText: "default" }).first().click();
  await page.waitForTimeout(800);
  const menu = await page.evaluate(() => {
    const cands = [...document.querySelectorAll("div,ul")].filter((d) => ["absolute", "fixed"].includes(getComputedStyle(d).position) && d.getBoundingClientRect().height > 60);
    return cands.map((d) => {
      const r = d.getBoundingClientRect();
      const s = getComputedStyle(d);
      return { cls: String(d.className).slice(0, 60), h: Math.round(r.height), bottom: Math.round(r.bottom), right: Math.round(r.right), ov: s.overflowY };
    }).slice(0, 6);
  });
  console.log("切り替えメニュー:", JSON.stringify(menu), "vh=900 vw=1440");
  await S(page, "probe-project-menu");
  await page.close();
}

// ---- メディア 200 枚 ----
{
  for (const w of [1440, 390]) {
    const page = await browser.newPage({ viewport: { width: w, height: 900 } });
    await open(page, "/p/default/assets", 2500);
    const n = await page.evaluate(() => document.querySelectorAll("img").length);
    const body = (await page.textContent("body")).replace(/\s+/g, " ");
    console.log(`${w} メディア: img=${n} / ${(body.match(/全 [\d,]+ 枚|全 [\d,]+ 件[^ ]*/) ?? ["?"])[0]}`);
    await S(page, `probe-media-${w}`);
    await page.close();
  }
}

await browser.close();
