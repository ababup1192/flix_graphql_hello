// GraphiQL の入口をブラウザで開き、Docs が描けて既定の query が返る事を見る。
//
// 使い方: CMS と vite を上げてから  node scripts/graphiql-smoke.mjs
// 見る物: Docs パネルに Query が出るか、⌘Enter で実行した結果に data が返るか、JS の例外が出ないか。
// プロジェクト slug は GRAPHIQL_PROJECT（既定 demo。CI の見本は default）。

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const project = process.env.GRAPHIQL_PROJECT ?? "demo";
const problems = [];
const steps = [];

function note(step, detail = "") {
  steps.push(`  OK  ${step}${detail ? " — " + detail : ""}`);
}

function fail(step, detail) {
  problems.push(`  NG  ${step} — ${detail}`);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

page.on("console", (message) => {
  if (message.type() === "error") problems.push(`  NG  コンソールのエラー — ${message.text().slice(0, 200)}`);
});
page.on("pageerror", (error) => problems.push(`  NG  JS の例外 — ${String(error).slice(0, 200)}`));
page.on("response", async (response) => {
  const url = response.url();
  if (!url.startsWith(base)) return;
  if (response.status() >= 400) problems.push(`  NG  ${response.status()} — ${url.replace(base, "")}`);
});

async function text() {
  return (await page.textContent("body")) ?? "";
}

async function waitForText(needle, step, timeout = 15000) {
  try {
    await page.waitForFunction((n) => document.body.innerText.includes(n), needle, { timeout });
    note(step);
    return true;
  } catch {
    fail(step, `「${needle}」が出ませんでした。今の画面: ${(await text()).replace(/\s+/g, " ").slice(0, 160)}`);
    return false;
  }
}

try {
  // 1. `/p/{slug}/graphiql` の読み替えで開く
  await page.goto(`${base}/p/${project}/graphiql`, { waitUntil: "networkidle" });
  await waitForText(project, "帯にプロジェクト slug が出る");
  await waitForText("リファレンス", "帯にリファレンスへのリンクが出る");

  // 2. Docs パネル（最初から開いている）に root の Query が出る
  const docs = page.locator(".graphiql-plugin");
  try {
    await docs.getByText("Query", { exact: true }).first().waitFor({ timeout: 15000 });
    note("Docs パネルに Query が出る");
  } catch {
    fail("Docs パネルに Query が出る", `今の画面: ${(await text()).replace(/\s+/g, " ").slice(0, 160)}`);
  }

  // 3. 既定の query を ⌘Enter で実行して data が返る
  await page.locator(".graphiql-query-editor .monaco-editor").first().click();
  await page.keyboard.press("ControlOrMeta+Enter");
  try {
    await page.waitForFunction(
      () => {
        const result = document.querySelector(".graphiql-response");
        return result !== null && result.textContent?.includes('"data"');
      },
      undefined,
      { timeout: 15000 },
    );
    note("既定の query を実行して data が返る");
  } catch {
    fail("既定の query を実行して data が返る", `結果: ${((await page.textContent(".graphiql-response")) ?? "").replace(/\s+/g, " ").slice(0, 200)}`);
  }
} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 300));
} finally {
  await browser.close();
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.error("\n" + problems.join("\n"));
  console.error(`\n${problems.length} 件の問題`);
  process.exit(1);
}
console.log("\n問題なし");
