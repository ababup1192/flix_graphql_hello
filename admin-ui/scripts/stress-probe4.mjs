import { chromium } from "playwright";
import { open } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const browser = await chromium.launch();
const S = (p, n) => p.screenshot({ path: `/tmp/ui-stress/${n}.png` });

// 親からはみ出した要素を、親の右端と比べて拾う
const outOfParent = (page) =>
  page.evaluate(() => {
    const out = [];
    for (const el of document.querySelectorAll("body *")) {
      const p = el.parentElement;
      if (!p) continue;
      const r = el.getBoundingClientRect();
      const pr = p.getBoundingClientRect();
      if (r.width === 0) continue;
      const st = getComputedStyle(p);
      if (st.overflowX !== "visible") continue;
      const over = Math.round(r.right - pr.right);
      if (over > 4 && p.clientWidth > 40) {
        out.push({
          tag: el.tagName.toLowerCase(),
          cls: String(el.className).slice(0, 60),
          text: (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 40),
          over,
          parentCls: String(p.className).slice(0, 50),
        });
      }
    }
    return out.slice(0, 12);
  });

// ボードのカード
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/c/zzstressart/board", 2500);
  console.log("board 親はみ出し:", JSON.stringify(await outOfParent(page), null, 0).slice(0, 1200));
  const tags = await page.evaluate(() => {
    const card = [...document.querySelectorAll("*")].find((e) => (e.textContent || "").includes("zz-stress タグ 20 個") && e.className.includes("rounded"));
    return card ? (card.textContent.match(/とても長いタグ|zz-stress-tag-\d+/g) || []).length : null;
  });
  console.log("ボードのカードに出たタグの数:", tags);
  await page.close();
}

// エディタ 20 タグ・参照の select
for (const w of [1440, 768, 390]) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, `/p/default/c/zzstressart/${k.manyTags}`, 2500);
  await S(page, `probe4-editor-tags20-${w}`);
  console.log(`${w} editor tags20 親はみ出し:`, JSON.stringify(await outOfParent(page)).slice(0, 800));
  await page.close();
}

// エディタ 長い英単語
for (const w of [1440, 1024, 768, 390]) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, `/p/default/c/zzstressart/${k.enEntry}`, 2500);
  await S(page, `probe4-editor-en-${w}`);
  console.log(`${w} editor en 親はみ出し:`, JSON.stringify(await outOfParent(page)).slice(0, 800));
  await page.close();
}

// 参照の候補の select
{
  const page = await browser.newPage({ viewport: { width: 1024, height: 900 } });
  await open(page, `/p/default/c/zzstressart/${k.jaEntry}`, 2500);
  const s = await page.evaluate(() => {
    const sels = [...document.querySelectorAll("select")];
    return sels.map((e) => ({ w: Math.round(e.getBoundingClientRect().width), n: e.options.length, first: e.options[1]?.text?.slice(0, 30) }));
  });
  console.log("1024 参照の select:", JSON.stringify(s));
  await S(page, "probe4-ref-1024");
  await page.close();
}

// 変更履歴の版の数（API は何版返すか）
{
  const r = await fetch("http://localhost:8080/p/default/admin/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query: `query ($i: ID!) { entry(id: $i) { versions { id label } } }`, variables: { i: k.jaEntry } }),
  }).then((x) => x.json());
  console.log("API が返す版の数:", r.data?.entry?.versions?.length, r.errors ? JSON.stringify(r.errors).slice(0, 200) : "");
}

// 予約が複数ある時
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, `/p/default/c/zzstressart/${k.enEntry}`, 2500);
  const t = (await page.textContent("body")).replace(/\s+/g, " ");
  console.log("予約の帯:", (t.match(/予約[\s\S]{0,200}/) || [""])[0].slice(0, 200));
  await S(page, "probe4-schedules");
  await page.close();
}

await browser.close();
