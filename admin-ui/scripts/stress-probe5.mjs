import { chromium } from "playwright";
import { open } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
const browser = await chromium.launch();

// ボードのカードの中で、英語の長い語がカードからはみ出しているか
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/c/zzstressart/board", 2500);
  const r = await page.evaluate(() => {
    const el = [...document.querySelectorAll("*")].find(
      (e) => e.children.length === 0 && (e.textContent || "").startsWith("Supercalifragilistic"),
    );
    if (!el) return "見つからない";
    const card = el.closest("a,div[class*=rounded]");
    const col = card?.parentElement?.closest("div[class*=rounded-md]");
    return {
      textRight: Math.round(el.getBoundingClientRect().right),
      cardRight: Math.round(card.getBoundingClientRect().right),
      colRight: col ? Math.round(col.getBoundingClientRect().right) : null,
      cardOverflowX: getComputedStyle(card).overflowX,
      wordBreak: getComputedStyle(el).overflowWrap + "/" + getComputedStyle(el).wordBreak,
    };
  });
  console.log("board 英語カード:", JSON.stringify(r));

  // 日本語の長いタイトルのカードの高さ
  const h = await page.evaluate(() => {
    const el = [...document.querySelectorAll("*")].find(
      (e) => e.children.length === 0 && (e.textContent || "").startsWith("あのイーハトーヴォ"),
    );
    return el ? Math.round(el.getBoundingClientRect().height) : null;
  });
  console.log("board 日本語カードのタイトルの高さ(px):", h);
  await page.close();
}

// 予約が 4 件ある時、右のレールに何件出るか
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, `/p/default/c/zzstressart/${k.enEntry}`, 2500);
  const n = await page.evaluate(() => (document.body.textContent.match(/実行待ち/g) || []).length);
  console.log("予約の行の数（API には 4 件）:", n);
  await page.screenshot({ path: "/tmp/ui-stress/probe5-schedules.png" });
  await page.close();
}

// 変更履歴の版の数（API 側）
{
  const r = await fetch("http://localhost:8080/p/default/admin/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query: `query ($i: ID!) { entry(id: $i) { versions { id } } }`, variables: { i: k.jaEntry } }),
  }).then((x) => x.json());
  console.log("API が返す版の数:", r.data?.entry?.versions?.length ?? JSON.stringify(r.errors).slice(0, 150));
}

// サイドバーの長い API 名の高さ
{
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await open(page, "/p/default/c/blogs", 2000);
  const s = await page.evaluate(() => {
    const els = [...document.querySelectorAll("a,button")].filter((e) => (e.textContent || "").includes("とても長い API の表示名"));
    return els.slice(0, 2).map((e) => ({ h: Math.round(e.getBoundingClientRect().height), lines: Math.round(e.getBoundingClientRect().height / 19) }));
  });
  console.log("サイドバーの長い API の行:", JSON.stringify(s));
  await page.close();
}

await browser.close();
