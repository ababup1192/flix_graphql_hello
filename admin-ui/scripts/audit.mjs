// 仕様どおりに動くかを一通り触って確かめる。**壊れた所を見つけるための物**で、
// 煙テスト（scripts/smoke.mjs）より細かく、直したい所を出す。
import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const admin = "http://localhost:8080/p/default/admin/graphql";
const gql = async (q) =>
  (await fetch(admin, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query: q }),
  })).json();

const bad = [];
const ok = [];
const note = (m) => ok.push(m);
const fail = (what, why) => bad.push(`${what} — ${why}`.slice(0, 260));

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
const jsErrors = [];
page.on("pageerror", (e) => jsErrors.push(String(e).slice(0, 160)));
page.on("console", (m) => { if (m.type() === "error") jsErrors.push(m.text().slice(0, 160)); });
const body = async () => (await page.textContent("body")).replace(/\s+/g, " ");
const open = async (path) => {
  await page.goto(base + path, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(900);
};

try {
  // ---- 1. 一覧の検索が打つ度に走らない ----
  await open("/p/default/c/blogs");
  let calls = 0;
  page.on("request", (r) => { if (r.url().includes("/admin/graphql")) calls += 1; });
  const search = page.locator("input").first();
  await search.click();
  calls = 0;
  await page.keyboard.type("Datalog", { delay: 60 });
  await page.waitForTimeout(200);
  const during = calls;
  await page.waitForTimeout(1200);
  if (during <= 2) note(`検索は打ち終わってから引く（打っている間 ${during} 本）`);
  else fail("検索は打ち終わってから引く", `打っている間に ${during} 本飛んだ`);
  if (await search.evaluate((el) => el === document.activeElement)) note("打っても入力欄から焦点が外れない");
  else fail("打っても入力欄から焦点が外れない", "外れました");
  const found = ((await body()).match(/全 (\d+) 件/) ?? [])[1];
  if (Number(found) > 0 && Number(found) < 20) note(`検索が効く（${found} 件）`);
  else fail("検索が効く", `全 ${found} 件`);

  // ---- 2. 絞り込み ----
  await open("/p/default/c/blogs");
  await page.getByRole("button", { name: "+ 絞り込み" }).click();
  await page.waitForTimeout(700);
  const items = await page.locator("select").nth(2).locator("option").allTextContents();
  if (items.length >= 10) note(`絞り込みの項目が全部出る（${items.length}）`);
  else fail("絞り込みの項目が全部出る", items.join("/"));

  // ---- 3. コードブロックの言語の面が切れない ----
  await open("/p/default/c/blogs/new");
  await page.locator("tiptap-editor .tt-body").click();
  await page.keyboard.type("```\n", { delay: 20 });
  await page.waitForTimeout(400);
  await page.locator(".tt-code-lang").first().click();
  await page.waitForTimeout(400);
  const clipped = await page.evaluate(() => {
    const pop = document.querySelector(".tt-code-pop");
    const box = document.querySelector(".tt-code");
    if (!pop || !box) return "無い";
    const p = pop.getBoundingClientRect();
    const b = box.getBoundingClientRect();
    const style = getComputedStyle(box);
    return JSON.stringify({ overflow: style.overflow, popBottom: Math.round(p.bottom), boxBottom: Math.round(b.bottom), popH: Math.round(p.height) });
  });
  if (clipped.includes('"overflow":"visible"') || clipped.includes('"overflow":"visible visible"')) note("言語の面が枠で切られない");
  else fail("言語の面が枠で切られない", clipped);
  if ((await page.locator(".tt-code-item").count()) > 10) note("言語の候補が並ぶ");
  else fail("言語の候補が並ぶ", `${await page.locator(".tt-code-item").count()} 件`);
  await page.keyboard.press("Escape");

  // ---- 4. 公開を終える。断られたら理由が出る ----
  // タグは公開中のブログから参照されているので、CMS が取り下げを断る
  const tags = (await gql(`{ contentTypes { id apiId } }`)).data.contentTypes.find((t) => t.apiId === "tags");
  const tagRows = (await gql(`{ entries(typeId: ${JSON.stringify(tags.id)}, first: 20) { nodes { id stage } } }`)).data.entries.nodes;
  const held = tagRows.find((r) => r.stage !== "DRAFT");
  if (held) {
    await open(`/p/default/c/tags/${held.id}`);
    const link = page.getByText("公開を終える");
    if ((await link.count()) > 0) {
      await link.first().click();
      await page.waitForTimeout(500);
      await page.getByRole("button", { name: "公開を終える" }).last().click();
      await page.waitForTimeout(2500);
      const after = await body();
      const stillOpen = after.includes("このコンテンツの公開を終えますか");
      const hasReason = after.includes("参照しています") || after.includes("公開中の entry");
      const now = (await gql(`{ entry(id: ${JSON.stringify(held.id)}) { stage } }`)).data.entry.stage;
      if (now === "DRAFT") {
        if (!stillOpen) note("公開を終えると確認が閉じる");
        else fail("公開を終えると確認が閉じる", "取り下げたのに確認が残る");
        await gql(`mutation { publishEntry(id: ${JSON.stringify(held.id)}) { stage } }`);
      } else if (hasReason) {
        note("断られたら理由が確認の中に出る");
      } else {
        fail("断られたら理由が出る", after.slice(0, 200));
      }
    } else {
      fail("公開を終えるがある", "リンクがありません");
    }
  }

  // ---- 5. 保存と公開の流れ ----
  await open("/p/default/c/blogs/new");
  // **数字を入れない**（見出しの検査で id と見分けが付かなくなる）
  const title = "audit-" + Math.random().toString(36).slice(2, 8).replace(/[0-9]/g, "x");
  await page.locator("input").first().fill(title);
  await page.waitForTimeout(300);
  if ((await body()).includes("未保存")) note("直すと「未保存」が出る");
  else fail("直すと「未保存」が出る", "出ません");
  await page.waitForTimeout(3000);
  if ((await body()).includes("未保存")) note("放っておいても勝手に保存しない");
  else fail("放っておいても勝手に保存しない", "自動で保存されました");
  await page.getByRole("button", { name: "下書き保存" }).click();
  await page.waitForTimeout(1800);
  if ((await body()).includes("保存済み")) note("下書き保存が効く");
  else fail("下書き保存が効く", (await body()).slice(0, 160));
  const madeUrl = page.url();

  await page.getByRole("button", { name: /^(公開する|変更を公開する)$/ }).first().click();
  await page.waitForTimeout(2500);
  if ((await body()).includes("直す所が")) note("必須が空なら公開前の確認で止まる");
  else fail("必須が空なら公開前の確認で止まる", (await body()).slice(0, 200));
  await page.getByRole("button", { name: "やめる" }).click();
  await page.waitForTimeout(400);
  if (!(await body()).includes("やめる")) note("確認を閉じられる");
  else fail("確認を閉じられる", "閉じません");

  // ---- 6. ボードの列と、コンテンツの見出し ----
  await open("/p/default/c/blogs/board");
  await page.waitForTimeout(1200);
  const cols = await page.locator("div.grid.grid-cols-3 > div").count();
  if (cols === 3) note("ボードが 3 列で出る");
  else fail("ボードが 3 列で出る", `${cols} 列`);
  const cards = await page.locator("div[draggable='true']").count();
  if (cards > 0) note(`ボードにカードが並ぶ（${cards}）`);
  else fail("ボードにカードが並ぶ", "0 枚");
  const cardText = (await page.locator("div[draggable='true']").first().textContent()) ?? "";
  if (!/[0-9a-f]{12}/.test(cardText.replace(/#\w{6}/, ""))) note("カードの見出しが id になっていない");
  else fail("カードの見出しが id になっていない", cardText.slice(0, 80));

  // ---- 7. ⌘K ----
  await open("/p/default/c/blogs");
  await page.keyboard.press("Meta+k");
  await page.waitForTimeout(700);
  if ((await page.locator("#" + "palette-input").count()) > 0) {
    note("⌘K で検索が開く");
    const focused = await page.evaluate(() => document.activeElement?.id ?? "");
    if (focused === "palette-input") note("開いた時に焦点が当たる");
    else fail("開いた時に焦点が当たる", `焦点=${focused}`);
    await page.keyboard.type("Datalog", { delay: 30 });
    await page.waitForTimeout(1500);
    const hits = await page.locator("#palette-input ~ * a, [role='option'], .palette-item").count();
    if ((await body()).includes("Datalog")) note("候補が出る");
    else fail("候補が出る", (await body()).slice(0, 160));
    await page.keyboard.press("Escape");
  } else {
    fail("⌘K で検索が開く", "開きません");
  }

  // ---- 8. 片付け ----
  await open(madeUrl.replace(base, ""));
  await page.waitForTimeout(1200);

  // ---- 9. 各画面が JS の例外なしに開く ----
  for (const [path, word] of [
    ["/p/default/c/blogs", "コンテンツ一覧"],
    ["/p/default/c/blogs/board", "下書き"],
    ["/p/default/c/blogs/schema", "表示名"],
    ["/p/default/c/blogs/settings", "エンドポイント"],
    ["/p/default/assets", "メディア"],
    ["/p/default/settings/members", "メンバー"],
    ["/p/default/settings/api-keys", "API キー"],
    ["/p/default/settings/project", "AI からつなぐ"],
    ["/account", "Personal Access Token"],
    ["/projects", "プロジェクト"],
  ]) {
    await open(path);
    if ((await body()).includes(word)) note(`${path} が描ける`);
    else fail(`${path} が描ける`, `「${word}」が出ない`);
  }
} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 300));
} finally {
  await browser.close();
  // 作った下書きを消す
  try {
    const types = (await gql(`{ contentTypes { id apiId } }`)).data.contentTypes;
    for (const type of types) {
      const rows = (await gql(`{ entries(typeId: ${JSON.stringify(type.id)}, first: 200) { nodes { id fields } } }`)).data.entries.nodes;
      for (const row of rows) {
        if (/^audit-/.test(String(row.fields?.title ?? ""))) await gql(`mutation { deleteEntry(id: ${JSON.stringify(row.id)}) }`);
      }
    }
  } catch {
    console.log("片付けに失敗");
  }
}

console.log(ok.map((m) => "  OK  " + m).join("\n"));
if (jsErrors.length > 0) {
  console.log("\nJS の例外:");
  for (const e of [...new Set(jsErrors)]) console.log("  - " + e);
}
if (bad.length > 0) {
  console.log("\n直す所:");
  for (const b of bad) console.log("  NG  " + b);
  process.exit(1);
}
console.log("\n問題なし");
