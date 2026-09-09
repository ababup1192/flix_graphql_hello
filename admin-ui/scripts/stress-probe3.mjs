import { chromium } from "playwright";
import { open, overflow } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const browser = await chromium.launch();
const S = (p, n) => p.screenshot({ path: `/tmp/ui-stress/${n}.png` });
const toBottom = (p) =>
  p.evaluate(() => {
    for (const el of document.querySelectorAll("body *"))
      if (["auto", "scroll"].includes(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight + 40)
        el.scrollTop = 1e7;
    window.scrollTo(0, 1e7);
  });

// メディアの一番下（打ち切りと「もっと」）
for (const w of [1440, 390]) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, "/p/default/assets", 3000);
  await toBottom(page);
  await page.waitForTimeout(800);
  await S(page, `probe3-media-bottom-${w}`);
  const t = (await page.textContent("body")).replace(/\s+/g, " ");
  console.log(`${w} メディアの下: ${t.slice(-160)}`);
  await page.close();
}

// 長いファイル名のタイルを探す
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/assets", 3000);
  const found = await page.evaluate(() => {
    const el = [...document.querySelectorAll("span")].find((s) => (s.textContent || "").includes("very-long-file-name"));
    if (!el) return "画面に出ていない（先頭 60 枚に入らない）";
    const r = el.getBoundingClientRect();
    const pr = el.parentElement.getBoundingClientRect();
    return { w: Math.round(r.width), parentW: Math.round(pr.width), over: Math.round(r.right - pr.right), clip: getComputedStyle(el).textOverflow };
  });
  console.log("長いファイル名:", JSON.stringify(found));
  await page.close();
}

// ボード（長いタイトル・20 タグ）
for (const w of [1440, 768]) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, "/p/default/c/zzstressart/board", 2500);
  await S(page, `probe3-board-${w}`);
  console.log(`${w} board:`, JSON.stringify(await overflow(page)).slice(0, 500));
  await page.close();
}

// 切り替えメニュー（画面が低い時）
{
  const page = await browser.newPage({ viewport: { width: 390, height: 640 } });
  const long = "とても長いプロジェクトの名前です".repeat(4);
  await page.route("**/account/graphql", async (route) => {
    const res = await route.fetch();
    let body = await res.text();
    try {
      const j = JSON.parse(body);
      const ps = j?.data?.me?.projects;
      if (Array.isArray(ps) && ps.length) {
        const more = [];
        for (let i = 0; i < 10; i += 1) {
          const c = JSON.parse(JSON.stringify(ps[0]));
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
  await open(page, "/p/default/c/blogs", 2500);
  await page.locator("button", { hasText: "default" }).first().click();
  await page.waitForTimeout(700);
  const m = await page.evaluate(() => {
    const d = [...document.querySelectorAll("div")].find((x) => String(x.className).includes("absolute z-40"));
    if (!d) return null;
    const r = d.getBoundingClientRect();
    return { h: Math.round(r.height), top: Math.round(r.top), bottom: Math.round(r.bottom), vh: window.innerHeight, ov: getComputedStyle(d).overflowY };
  });
  console.log("低い画面での切り替えメニュー:", JSON.stringify(m));
  await S(page, "probe3-project-menu-390");
  await page.close();
}

// プロジェクト選択の画面（12 個・長い名前）
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
        const more = [];
        for (let i = 0; i < 10; i += 1) {
          const c = JSON.parse(JSON.stringify(ps[0]));
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
  await open(page, "/projects", 2500);
  await S(page, "probe3-projects12");
  console.log("projects 12:", JSON.stringify(await overflow(page)).slice(0, 500));
  await page.close();
}

// 空の時（コンテンツ 0 / フィールド 0 / タグ 0 / 履歴 0）
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  for (const [n, p] of [
    ["entries0", "/p/default/c/zzstressempty"],
    ["fields0", "/p/default/c/zzstressempty/schema"],
    ["board0", "/p/default/c/zzstressempty/board"],
  ]) {
    await open(page, p, 2000);
    await S(page, `probe3-${n}`);
    const t = (await page.textContent("body")).replace(/\s+/g, " ");
    console.log(`空 ${n}: ${t.slice(0, 260)}`);
  }
  // 履歴 0 の entry（作ったばかりの物）
  await open(page, `/p/default/c/zzstressart/${k.manyTags}`, 2500);
  await S(page, "probe3-history0");
  await page.close();
}

// メディア 0 枚（返事を空に差し替え）
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.route("**/admin/graphql", async (route) => {
    const res = await route.fetch();
    let body = await res.text();
    try {
      const j = JSON.parse(body);
      if (j?.data?.assets) {
        j.data.assets.nodes = [];
        if (j.data.assets.totalCount !== undefined) j.data.assets.totalCount = 0;
        if (j.data.assets.pageInfo) j.data.assets.pageInfo.hasNextPage = false;
        body = JSON.stringify(j);
      }
    } catch (e) {}
    route.fulfill({ response: res, body });
  });
  await open(page, "/p/default/assets", 2500);
  await S(page, "probe3-media0");
  console.log("メディア 0:", (await page.textContent("body")).replace(/\s+/g, " ").slice(0, 200));
  await page.close();
}

await browser.close();
