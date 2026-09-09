import { chromium } from "playwright";
const base = "http://localhost:5173";
const admin = "http://localhost:8080/p/default/admin/graphql";
const gql = async (q) => (await fetch(admin, { method: "POST", headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" }, body: JSON.stringify({ query: q }) })).json();
const types = (await gql(`{ contentTypes { apiId name } }`)).data.contentTypes;
const longOne = types.find((t) => t.name.length > 30) ?? types[0];
console.log("使う API:", longOne.apiId, "／名前の長さ", longOne.name.length);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
await page.goto(`${base}/p/default/c/${longOne.apiId}`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(2000);
const look = await page.evaluate(() => {
  const h1 = document.querySelector("h1");
  const add = [...document.querySelectorAll("button")].find((b) => b.textContent.includes("追加"));
  const board = [...document.querySelectorAll("button")].find((b) => b.textContent.includes("ボード"));
  const order = [...document.querySelectorAll("select")].pop();
  const box = (el) => (el ? { w: Math.round(el.getBoundingClientRect().width), h: Math.round(el.getBoundingClientRect().height) } : null);
  return JSON.stringify({
    h1: box(h1),
    h1Lines: h1 ? Math.round(h1.getBoundingClientRect().height / parseFloat(getComputedStyle(h1).lineHeight)) : 0,
    add: box(add),
    board: box(board),
    order: box(order),
    横スクロール: document.documentElement.scrollWidth > window.innerWidth,
  });
});
console.log(look);
await page.screenshot({ path: "/tmp/header.png", clip: { x: 240, y: 90, width: 1200, height: 220 } });
await browser.close();
