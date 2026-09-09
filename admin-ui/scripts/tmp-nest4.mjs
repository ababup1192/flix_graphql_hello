import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("pageerror", (e) => console.log("例外: " + String(e).slice(0, 200)));
page.on("console", (m) => { if (m.type() === "error") console.log("エラー: " + m.text().slice(0, 200)); });
await page.goto("http://localhost:5173/p/default/c/blogs/new", { waitUntil: "domcontentloaded" });
await page.waitForSelector("tiptap-editor .tt-body", { timeout: 20000 });
await page.waitForTimeout(1200);
const P = (t) => ({ type: "paragraph", content: [{ type: "text", text: t }] });
const inner = { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [P("中の表")] }] }] };
const doc = { type: "doc", content: [
  { type: "table", content: [{ type: "tableRow", content: [
    { type: "tableHeader", content: [P("見出し"), inner] },
    { type: "tableCell", content: [{ type: "blockquote", content: [P("引用")] }] },
  ] }] },
  { type: "paragraph", content: [{ type: "text", text: "x", marks: [{ type: "sub" }, { type: "sup" }] }] },
]};
await page.evaluate((d) => document.querySelector("tiptap-editor").setAttribute("doc", JSON.stringify(d)), doc);
await page.waitForTimeout(1200);
console.log("読み込めた本文:", await page.evaluate(() => document.querySelector("tiptap-editor .tt-body").innerHTML.slice(0, 400)));
await browser.close();
