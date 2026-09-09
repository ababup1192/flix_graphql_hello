import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("pageerror", (e) => console.log("例外: " + String(e).slice(0, 200)));
await page.goto("http://localhost:5173/p/default/c/blogs/new", { waitUntil: "domcontentloaded" });
await page.waitForSelector("tiptap-editor .tt-body", { timeout: 20000 });
await page.waitForTimeout(1200);
const body = page.locator("tiptap-editor .tt-body");
const doc = () => page.evaluate(() => JSON.parse(document.querySelector("tiptap-editor").getAttribute("doc") || "{}"));
const kinds = (node) => {
  const out = [];
  const walk = (n, trail) => { const next = [...trail, n.type]; out.push(next.join(">")); (n.content ?? []).forEach((c) => walk(c, next)); };
  (node.content ?? []).forEach((c) => walk(c, []));
  return out;
};
console.log("マークの排他:", JSON.stringify(await page.evaluate(() => {
  const m = document.querySelector("tiptap-editor").editor.schema.marks;
  return { sub: m.sub.spec.excludes, sup: m.sup.spec.excludes, highlight: m.highlight.spec.excludes ?? "(既定)" };
})));
await body.click();
await page.locator('.tt-tool[title="表"]').click();
await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
await page.locator(".tt-size-cell").nth(1 * 8 + 1).click();
await page.waitForTimeout(600);
for (const title of ["表", "引用", "コードブロック", "箇条書き", "区切り線", "画像"]) {
  await page.locator(".tt-body table th").first().click();
  await page.waitForTimeout(200);
  if (title === "表") {
    await page.locator('.tt-tool[title="表"]').click();
    await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
    await page.locator(".tt-size-cell").nth(1 * 8 + 1).click();
  } else {
    await page.locator(`.tt-tool[title="${title}"]`).click();
  }
  await page.waitForTimeout(400);
  const inside = kinds(await doc()).filter((k) => /^table>tableRow>table(Header|Cell)>(?!paragraph$)/.test(k));
  console.log(`セルの中で「${title}」:`, inside.join(" / ") || "入らない");
  await page.keyboard.press("Escape");
}
// 上付き＋下付き
await page.reload({ waitUntil: "domcontentloaded" });
await page.waitForSelector("tiptap-editor .tt-body", { timeout: 20000 });
await page.waitForTimeout(1200);
await body.click();
await page.locator('.tt-tool[title="上付き"]').click();
await page.locator('.tt-tool[title="下付き"]').click();
await page.keyboard.type("a");
await page.waitForTimeout(400);
console.log("上付き→下付きの順に押す:", JSON.stringify((await doc()).content?.[0]?.content?.[0]?.marks ?? "印なし"));
console.log("本文:", await page.evaluate(() => document.querySelector("tiptap-editor .tt-body").innerHTML.slice(0, 120)));
await browser.close();
