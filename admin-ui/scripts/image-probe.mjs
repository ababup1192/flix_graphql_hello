import { chromium } from "playwright";
const base = "http://localhost:5173";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
const say = (m) => console.log(m);
page.on("pageerror", (e) => say("例外: " + String(e).slice(0, 160)));
await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "domcontentloaded" });
await page.waitForSelector("tiptap-editor .tt-body", { timeout: 20000 });
await page.waitForTimeout(800);
// ツールバーに画像の入口があるか
const tools = await page.locator(".tt-tool").evaluateAll((els) => els.map((e) => e.title || e.textContent));
say("ツールバー: " + JSON.stringify(tools));
// TipTap の image を挿してみて、CMS が受けるか
await page.locator("tiptap-editor .tt-body").click();
const inserted = await page.evaluate(() => {
  const el = document.querySelector("tiptap-editor");
  const doc = JSON.parse(el.getAttribute("doc") || "{}");
  return JSON.stringify(doc).slice(0, 120);
});
say("今の doc: " + inserted);
say("画像を貼る入口: " + (tools.some((t) => (t || "").includes("画像")) ? "ある" : "無い"));
await browser.close();
