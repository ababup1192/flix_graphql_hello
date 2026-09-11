// 実際の画面をブラウザで触る。人が見つける前に、詰まりと JS の例外を見つける。
//
// 使い方: CMS と vite を上げてから  npm run smoke
// 見る物: 各画面が描けるか、JS の例外が出ないか、リクエストが 4xx/5xx にならないか。

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
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

async function waitForText(needle, step, timeout = 8000) {
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
  // 1. 入口
  await page.goto(base + "/", { waitUntil: "networkidle" });
  await waitForText("default", "起動して me が返る");

  // 2. コンテンツ一覧
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await waitForText("ブログ", "コンテンツ一覧を直接開ける");

  // 3. API スキーマ
  await page.goto(base + "/p/default/c/blogs/schema", { waitUntil: "networkidle" });
  await waitForText("フィールド", "API スキーマが描ける");

  // 4. メンバー
  await page.goto(base + "/p/default/settings/members", { waitUntil: "networkidle" });
  await waitForText("メンバー", "メンバーの画面が描ける");

  // 5. プロジェクト選択
  await page.goto(base + "/projects", { waitUntil: "networkidle" });
  await waitForText("プロジェクトを選ぶ", "プロジェクト選択が描ける");

  // 6. 新規作成 → 入力 → 下書き保存（保存は人が押す）
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  if (await waitForText("タイトル", "新規作成が描ける")) {
    const title = `smoke-test ${Date.now()}`;
    await page.locator("input").first().fill(title);
    await waitForText("未保存", "押すまで保存されない");
    await page.getByRole("button", { name: "下書き保存" }).click();
    await page.waitForTimeout(1200);
    await waitForText("保存済み", "下書き保存が効く");
  }

  // 7. リッチエディタ
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
  const editor = page.locator("tiptap-editor .tt-body");
  if ((await editor.count()) === 0) {
    fail("リッチエディタが出る", "tiptap-editor が描かれていません");
  } else {
    note("リッチエディタが出る");
    if ((await page.locator(".tt-tool").count()) >= 10) note("リッチエディタのツールバーが出る");
    else fail("リッチエディタのツールバーが出る", `ボタン ${await page.locator(".tt-tool").count()} 個`);
    if ((await page.locator(".tt-block").count()) === 1) note("段落の種類のドロップダウンが出る");
    else fail("段落の種類のドロップダウンが出る", "見つかりません");
    await page.locator("input").first().fill(`smoke-rich ${Date.now()}`);
    await editor.click();
    await page.keyboard.type("見出しの下の段落");
    // 見出しにしてみる（ドロップダウンで選ぶ）
    await page.locator(".tt-block").selectOption("h2");
    await page.waitForTimeout(400);
    await page.getByRole("button", { name: "下書き保存" }).click();
    await page.waitForTimeout(1200);
    await waitForText("保存済み", "リッチエディタの入力が保存される");
    const doc = await page.evaluate(() => document.querySelector("tiptap-editor")?.getAttribute("doc") ?? "");
    if (doc.includes("見出しの下の段落")) note("doc に本文が入る");
    else fail("doc に本文が入る", `doc = ${doc.slice(0, 120)}`);
    if (doc.includes("heading")) note("ツールバーで見出しにできる");
    else fail("ツールバーで見出しにできる", `doc = ${doc.slice(0, 160)}`);
  }

  // 7.5 コードブロック（``` で作り、言語はブロックの下の帯で選ぶ）
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(1000);
  await page.locator("tiptap-editor .tt-body").click();
  await page.keyboard.type("```\n");
  await page.waitForTimeout(500);
  if ((await page.locator(".tt-code").count()) === 1) note("``` でコードブロックになる");
  else fail("``` でコードブロックになる", `${await page.locator(".tt-code").count()} 個`);
  await page.keyboard.type('def main(): Unit \\ IO = println("hi")');
  await page.waitForTimeout(300);
  if ((await page.locator(".tt-language").count()) === 0) note("ツールバーに言語のセレクトが無い");
  else fail("ツールバーに言語のセレクトが無い", "残っています");
  const langButton = page.locator(".tt-code-lang").first();
  if ((await langButton.count()) === 1) {
    note("ブロックの下の帯で言語を選べる");
    await langButton.click();
    await page.waitForTimeout(400);
    await langButton.fill("fli");
    await page.waitForTimeout(300);
    const hits = await page.locator(".tt-code-item").allTextContents();
    if (hits.join("/") === "FLflix") note("打って言語を絞れる");
    else fail("打って言語を絞れる", hits.join("/"));
    await page.keyboard.press("Enter");
    await page.waitForTimeout(1200);
    if ((await page.locator(".tt-body pre code span").count()) > 0) note("選んだ言語で色が付く");
    else fail("選んだ言語で色が付く", "色の span がありません");
  } else {
    fail("ブロックの下の帯で言語を選べる", "欄がありません");
  }

  // 7.55 数式と図（CMS は元から受ける。管理画面が追いついていなかった）
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(1000);
  await page.locator("tiptap-editor .tt-body").click();
  await page.keyboard.type("式は $E = mc^2$ です。", { delay: 10 });
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(700);
  if ((await page.locator(".tt-math .katex").count()) > 0) note("文の中の数式が描かれる");
  else fail("文の中の数式が描かれる", "katex がありません");

  await page.keyboard.press("Control+End");
  await page.keyboard.press("Enter");
  await page.keyboard.type("$$ ", { delay: 10 });
  await page.waitForTimeout(500);
  if ((await page.locator(".tt-mathblock").count()) > 0) {
    await page.locator(".tt-mathblock-src").fill("\\frac{1}{3}");
    await page.waitForTimeout(800);
    if ((await page.locator(".tt-mathblock-out .katex").count()) > 0) note("段落の数式が描かれる");
    else fail("段落の数式が描かれる", "katex がありません");
  } else {
    fail("段落の数式が描かれる", "$$ でブロックにならない");
  }

  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(900);
  await page.locator("tiptap-editor .tt-body").click();
  await page.keyboard.type("```mermaid\n", { delay: 10 });
  await page.waitForTimeout(400);
  await page.keyboard.type("graph TD\n  A[入力] --> B[検査]", { delay: 10 });
  await page.waitForTimeout(3500);
  if ((await page.locator(".tt-diagram svg").count()) > 0) note("mermaid の図が描かれる");
  else fail("mermaid の図が描かれる", (await page.locator(".tt-diagram").textContent()) ?? "図がありません");

  // 7.6 コンテンツへのリンク（URL とコンテンツを 1 つの面で切り替える）
  // **新しく開き直す**（前の検査でカーソルがコードブロックの中にいる）。
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(1000);
  await page.locator("tiptap-editor .tt-body").click();
  await page.keyboard.type("この記事も読んでください");
  await page.keyboard.down("Shift");
  for (let i = 0; i < 6; i += 1) await page.keyboard.press("ArrowLeft");
  await page.keyboard.up("Shift");
  await page.locator(".tt-tool[title='リンク']").click();
  await page.waitForTimeout(600);
  await page.waitForTimeout(1500);
  if ((await page.locator("[data-link-row]").count()) > 0) {
    note("リンクの面にコンテンツの候補が出る");
    // **URL を打つと一番上に「URL」の見出しとその行が出る**（タブで切り替えない）
    await page.locator("#link-pick-input").fill("https://example.com");
    await page.waitForTimeout(600);
    const head = await page.locator("[role='dialog'] .text-\\[10px\\].font-semibold").first().textContent();
    const first = await page.locator("[data-link-row]").first().textContent();
    if (head === "URL" && (first ?? "").includes("https://example.com")) note("URL を打つとその行が出る");
    else fail("URL を打つとその行が出る", `${head} / ${first ?? ""}`);

    await page.locator("#link-pick-input").fill("");
    await page.waitForTimeout(1200);
    await page.locator("[data-link-row]").first().click();
    await page.waitForTimeout(600);
    const linked = await page.locator("tiptap-editor .tt-body").innerHTML();
    if (linked.includes("data-entry-id")) note("コンテンツへのリンクが張れる");
    else fail("コンテンツへのリンクが張れる", linked.slice(0, 200));
  } else {
    fail("リンクの面にコンテンツの候補が出る", "候補がありません");
  }

  // 8. 一覧に出る
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await waitForText("smoke-test", "作った物が一覧に出る");

  // 9. 既にあるコンテンツを開くと中身が出る
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  const existing = page.locator("a").filter({ hasText: "Datalog" }).first();
  if ((await existing.count()) > 0) {
    await existing.click();
    await page.waitForTimeout(2000);
    const title = await page.locator("input").first().inputValue();
    if (title.includes("Datalog")) note("開いたコンテンツに中身が入っている");
    else fail("開いたコンテンツに中身が入っている", `タイトルの欄 = ${JSON.stringify(title)}`);
    const refValue = await page.locator("select").first().inputValue();
    if (refValue.length > 0) note("参照の著者が選ばれている");
    else fail("参照の著者が選ばれている", "空でした");
    if ((await page.locator("svg circle").count()) > 0) note("文字数のゲージが出る");
    else fail("文字数のゲージが出る", "見つかりません");
    const doc = await page.evaluate(() => document.querySelector("tiptap-editor")?.getAttribute("doc") ?? "");
    if (doc.includes("判定を")) note("本文も入っている");
    else fail("本文も入っている", `doc = ${doc.slice(0, 120)}`);
  }

  // 9.5 ボード
  await page.goto(base + "/p/default/c/blogs/board", { waitUntil: "networkidle" });
  await page.waitForTimeout(1500);
  const board = await text();
  if (board.includes("下書き") && board.includes("公開中")) note("ボードが列で描ける");
  else fail("ボードが列で描ける", board.replace(/\s+/g, " ").slice(0, 200));

  // 10. 公開の流れ
  const first = page.locator("a", { hasText: "smoke-test" }).first();
  if ((await first.count()) > 0) {
    await first.click();
    await page.waitForTimeout(1200);
    const check = page.getByRole("button", { name: /^(公開する|変更を公開する)$/ });
    if ((await check.count()) > 0) {
      await check.first().click();
      await page.waitForTimeout(2000);
      const body = await text();
      if (body.includes("公開できます") || body.includes("直す所が")) note("公開前の確認が返る");
      else fail("公開前の確認が返る", body.replace(/\s+/g, " ").slice(0, 200));
      const stop = page.getByRole("button", { name: "やめる" });
      if ((await stop.count()) > 0) {
        await stop.click();
        await page.waitForTimeout(400);
        if (!(await text()).includes("やめる")) note("公開前の確認を閉じられる");
        else fail("公開前の確認を閉じられる", "閉じません");
      } else {
        fail("公開前の確認が開く", "やめるが見つかりません");
      }
    } else {
      fail("公開のボタンがある", (await text()).replace(/\s+/g, " ").slice(0, 160));
    }
  }
  // 10. 一覧の絞り込みが URL に残る
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(400);
  const stage = page.locator("select").first();
  if ((await stage.count()) > 0) {
    await stage.selectOption("DRAFT");
    await page.waitForTimeout(1200);
    if (page.url().includes("where=DRAFT")) note("絞り込みが URL に残る");
    else fail("絞り込みが URL に残る", page.url());
    await page.reload({ waitUntil: "networkidle" });
    await page.waitForTimeout(800);
    const selected = await page.locator("select").first().inputValue();
    if (selected === "DRAFT") note("再読み込みしても絞り込みが残る");
    else fail("再読み込みしても絞り込みが残る", `select = ${selected}`);
  } else {
    fail("絞り込みの select がある", (await text()).replace(/\s+/g, " ").slice(0, 160));
  }

  // 10.7 枠（プロジェクト切替・自分メニュー・テーマ・タブ・パンくず）
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(700);
  const shell = await text();
  if (shell.includes("API スキーマ") && shell.includes("API 設定")) note("型の画面にタブが出る");
  else fail("型の画面にタブが出る", shell.replace(/\s+/g, " ").slice(0, 160));

  await page.locator("button", { hasText: "dev@localhost" }).first().click();
  await page.waitForTimeout(400);
  const menu = await text();
  if (menu.includes("ログアウト") && menu.includes("ダーク")) note("自分のメニューが開く");
  else fail("自分のメニューが開く", menu.replace(/\s+/g, " ").slice(0, 200));

  await page.locator("button", { hasText: "ダーク" }).first().click();
  await page.waitForTimeout(500);
  const theme = await page.evaluate(() => document.documentElement.getAttribute("data-theme"));
  if (theme === "dark") note("ダークテーマに切り替わる");
  else fail("ダークテーマに切り替わる", `data-theme = ${theme}`);
  await page.evaluate(() => localStorage.setItem("theme", "system"));

  // 10.8 API 設定
  await page.goto(base + "/p/default/c/blogs/settings", { waitUntil: "networkidle" });
  await waitForText("エンドポイント", "API 設定の画面が描ける");

  // 10.9 絞り込み（条件を足す形。フィールドの種類で演算子が変わる）
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(1000);
  const totalOf = async () => Number(((await text()).match(/全 (\d+) 件/) ?? [0, 0])[1]);
  const all = await totalOf();
  await page.getByRole("button", { name: "+ 絞り込み" }).click();
  await page.waitForTimeout(800);
  const itemSelect = page.locator("select").nth(2);
  const items = await itemSelect.locator("option").allTextContents();
  if (items.length > 5) note(`絞り込みに全部の項目が出る（${items.length} 件）`);
  else fail("絞り込みに全部の項目が出る", items.join("/"));

  // 参照（タグ）— 候補は検索して選ぶ。id は打たせない
  await itemSelect.selectOption({ label: "タグ" });
  await page.waitForTimeout(1200);
  const ops = await page.locator("select").nth(3).locator("option").allTextContents();
  if (ops.join("/") === "を含む/未入力") note("複数の参照は「含む」だけ出る");
  else fail("複数の参照は「含む」だけ出る", ops.join("/"));
  const candidates = page.locator("div.max-h-40 button");
  if ((await candidates.count()) > 0) {
    note("参照の候補が名前で出る");
    await candidates.first().click();
    await page.waitForTimeout(300);
    await page.getByRole("button", { name: "絞り込む" }).click();
    await page.waitForTimeout(1500);
    const narrowed = await totalOf();
    if (narrowed > 0 && narrowed < all) note(`参照で絞れる（${narrowed} / ${all} 件）`);
    else fail("参照で絞れる", `${narrowed} / ${all}`);
    if (page.url().includes("f=tags")) note("条件が URL に残る");
    else fail("条件が URL に残る", page.url());

    // 日時をもう 1 つ足す（条件は 2 つ以上持てる）
    await page.getByRole("button", { name: "+ 絞り込み" }).click();
    await page.waitForTimeout(500);
    await page.locator("select").nth(2).selectOption({ label: "公開日" });
    await page.waitForTimeout(400);
    await page.locator("input[type=date]").fill("2026-08-10");
    await page.getByRole("button", { name: "絞り込む" }).click();
    await page.waitForTimeout(1500);
    const both = await totalOf();
    if ((await page.locator("button.rounded-full").count()) === 2) note("条件を 2 つ以上足せる");
    else fail("条件を 2 つ以上足せる", `チップ ${await page.locator("button.rounded-full").count()} 個`);
    if (both <= narrowed) note(`日時でも絞れる（${both} 件）`);
    else fail("日時でも絞れる", `${both} > ${narrowed}`);

    await page.reload({ waitUntil: "networkidle" });
    await page.waitForTimeout(1800);
    if ((await totalOf()) === both) note("再読み込みしても条件が残る");
    else fail("再読み込みしても条件が残る", `${await totalOf()} != ${both}`);

    await page.locator("button.rounded-full").first().click();
    await page.waitForTimeout(1500);
    if ((await page.locator("button.rounded-full").count()) === 1) note("条件を 1 つずつ外せる");
    else fail("条件を 1 つずつ外せる", `チップ ${await page.locator("button.rounded-full").count()} 個`);
  } else {
    fail("参照の候補が名前で出る", "候補がありません");
  }

  // 11. API キーと Webhook
  await page.goto(base + "/p/default/settings/api-keys", { waitUntil: "networkidle" });
  if (await waitForText("API キー", "API キーの画面が描ける")) {
    // **後始末する**（人のプロジェクトにテストのゴミを残さない）。
    const keyName = `smoke-test-${Date.now()}`;
    await page.locator("input").first().fill(keyName);
    await page.locator("button", { hasText: "発行" }).first().click();
    await page.waitForTimeout(1500);
    if ((await text()).includes("この値はこの画面を閉じると二度と出ません")) note("キーを発行して生の値が出る");
    else fail("キーを発行して生の値が出る", (await text()).replace(/\s+/g, " ").slice(0, 200));
    await page.locator("button", { hasText: "控えました" }).first().click();
    await page.waitForTimeout(600);
    const revoke = page.locator("button", { hasText: "失効" }).first();
    if ((await revoke.count()) > 0) {
      await revoke.click();
      await page.waitForTimeout(1000);
      note("発行したキーを片付ける");
    }
  }

  // 12. メディアのアップロード
  await page.goto(base + "/p/default/assets", { waitUntil: "networkidle" });
  if (await waitForText("メディア", "メディアの画面が描ける")) {
    await page.setInputFiles("#asset-file", {
      name: `smoke-${Date.now()}.png`,
      mimeType: "image/png",
      // 1x1 の PNG
      buffer: Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        "base64"
      ),
    });
    await page.waitForTimeout(4000);
    const body = await text();
    if (body.includes("smoke-")) note("アップロードした物が並ぶ");
    else fail("アップロードした物が並ぶ", body.replace(/\s+/g, " ").slice(0, 200));
  }

  // 13. ⌘K でコンテンツを探して飛ぶ
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
  // ボタンからも開ける事を見る。
  const searchButton = page.locator("button", { hasText: "検索" }).first();
  if ((await searchButton.count()) > 0) {
    await searchButton.click();
    await page.waitForTimeout(400);
    if ((await page.locator("#palette-input").count()) > 0) {
      note("検索のボタンから開ける");
      await page.keyboard.press("Escape");
      await page.waitForTimeout(300);
    } else {
      fail("検索のボタンから開ける", "開きませんでした");
    }
  } else {
    fail("検索のボタンがある", (await text()).replace(/\s+/g, " ").slice(0, 160));
  }
  await page.keyboard.press("Meta+k");
  await page.waitForTimeout(400);
  if ((await page.locator("#palette-input").count()) === 0) {
    fail("⌘K で検索が開く", (await text()).replace(/\s+/g, " ").slice(0, 160));
  } else {
    note("⌘K で検索が開く");
    await page.locator("#palette-input").fill("Flix");
    await page.waitForTimeout(2000);
    const hit = page.locator("button", { hasText: "Flix" }).first();
    if ((await hit.count()) > 0) {
      note("コンテンツが候補に出る");
      // 上下キーと Enter でも飛べる事を見る。
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("ArrowUp");
      await hit.click();
      await page.waitForTimeout(1200);
      if (page.url().includes("/c/")) note("選んだコンテンツに飛ぶ");
      else fail("選んだコンテンツに飛ぶ", page.url());
    } else {
      fail("コンテンツが候補に出る", (await text()).replace(/\s+/g, " ").slice(0, 200));
    }
  }

  // 13.5 API プレビュー（一覧と 1 件。専用のタブではなく引き出し）
  await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  const apiButton = page.getByRole("button", { name: "API", exact: true });
  if ((await apiButton.count()) === 0) {
    fail("一覧に API のボタンがある", (await text()).replace(/\s+/g, " ").slice(0, 160));
  } else {
    await apiButton.first().click();
    await page.waitForTimeout(1500);
    const box = page.locator("textarea");
    if ((await box.count()) === 0) {
      fail("API プレビューの引き出しが開く", (await text()).replace(/\s+/g, " ").slice(0, 160));
    } else {
      note("一覧から API プレビューが開く");
      const listQuery = await box.inputValue();
      if (listQuery.includes("blogs(first:") && listQuery.includes("totalCount")) note("一覧の query を作る");
      else fail("一覧の query を作る", listQuery.slice(0, 160));
      await page.getByRole("button", { name: "送る" }).click();
      await page.waitForTimeout(1800);
      const answer = (await page.locator("pre").first().textContent()) ?? "";
      if (answer.includes('"blogs"') && !answer.includes('"errors"')) note("一覧の JSON が返る");
      else fail("一覧の JSON が返る", answer.replace(/\s+/g, " ").slice(0, 200));

      await page.getByRole("button", { name: "1 件" }).click();
      await page.waitForTimeout(800);
      const oneQuery = await box.inputValue();
      if (/blog\(id: "/.test(oneQuery)) note("1 件の query を作る");
      else fail("1 件の query を作る", oneQuery.slice(0, 160));
      await page.getByRole("button", { name: "送る" }).click();
      await page.waitForTimeout(1800);
      const one = (await page.locator("pre").first().textContent()) ?? "";
      if (one.includes('"blog"') && !one.includes('"errors"')) note("1 件の JSON が返る");
      else fail("1 件の JSON が返る", one.replace(/\s+/g, " ").slice(0, 200));

      await page.getByRole("button", { name: "閉じる" }).click();
      await page.waitForTimeout(500);
      if ((await page.locator("textarea").count()) === 0) note("引き出しを閉じられる");
      else fail("引き出しを閉じられる", "閉じません");
    }
  }

  // 13.6 被リンク（このコンテンツはどこから参照されているか）
  await page.goto(base + "/p/default/c/tags", { waitUntil: "networkidle" });
  await page.waitForTimeout(900);
  const tagLink = page.locator(
    "a[href*='/c/tags/']:not([href$='/schema']):not([href$='/board']):not([href$='/settings']):not([href$='/new'])"
  );
  if ((await tagLink.count()) > 0) {
    await tagLink.first().click();
    await page.waitForTimeout(2200);
    const shown = await text();
    if (/参照されています（\d+）/.test(shown)) note("被リンクの件数が出る");
    else fail("被リンクの件数が出る", shown.replace(/\s+/g, " ").slice(0, 200));
    if (shown.includes("公開中の参照") && shown.includes("下書きの参照")) note("公開と下書きを分けて出す");
    else fail("公開と下書きを分けて出す", shown.replace(/\s+/g, " ").slice(0, 200));
    if (shown.includes("公開を終える事も削除する事もできません")) note("止まる理由を先に出す");
    else fail("止まる理由を先に出す", "説明がありません");
  } else {
    fail("タグを開ける", "行のリンクが見つかりません");
  }

  // 13.65 API のアイコン（何度でも選び直せる）
  await page.goto(base + "/p/default/c/blogs/schema", { waitUntil: "networkidle" });
  await page.waitForTimeout(1200);
  const iconButton = page.locator("button[title='アイコンを選ぶ']");
  if ((await iconButton.count()) > 0) {
    note("題の左にアイコンが出る");
    await iconButton.click();
    await page.waitForTimeout(600);
    const tiles = page.locator("div.grid-cols-6 button");
    if ((await tiles.count()) > 10) note(`アイコンを選べる（${await tiles.count()} 種類）`);
    else fail("アイコンを選べる", `${await tiles.count()} 種類`);
    // **元に戻す**（見本のアイコンを煙テストが変えない）
    await page.locator("button[title='本']").click();
    await page.waitForTimeout(1500);
    if ((await text()).includes("アイコンを選ぶ") === false) note("選ぶと閉じる");
    else fail("選ぶと閉じる", "開いたままです");
  } else {
    fail("題の左にアイコンが出る", "ボタンがありません");
  }

  // 13.7 API スキーマ（掴んで並べ替え、行を押して設定）
  await page.goto(base + "/p/default/c/blogs/schema", { waitUntil: "networkidle" });
  await page.waitForTimeout(1000);
  const fieldRows = page.locator("div[draggable='true']");
  const fieldNames = async () =>
    (await page.locator("div[draggable='true'] .font-mono").allTextContents()).map((t) => t.trim());
  const order = await fieldNames();
  if (order.length >= 3) {
    note("スキーマの行が掴める形で出る");
    await fieldRows.nth(0).dragTo(fieldRows.nth(2));
    await page.waitForTimeout(1500);
    const moved = await fieldNames();
    if (moved.join(",") !== order.join(",")) note("掴んで並べ替えられる");
    else fail("掴んで並べ替えられる", moved.join(","));
    // **元に戻す**（煙テストが見本のスキーマを崩さない）
    await fieldRows.nth(2).dragTo(fieldRows.nth(0));
    await page.waitForTimeout(1500);
    if ((await fieldNames()).join(",") === order.join(",")) note("並びを元に戻せる");
    else fail("並びを元に戻せる", (await fieldNames()).join(","));

    await fieldRows.nth(0).click();
    await page.waitForTimeout(600);
    const panel = await text();
    if (panel.includes("入力の決まり")) note("行を押すと設定が右に出る");
    else fail("行を押すと設定が右に出る", panel.replace(/\s+/g, " ").slice(0, 160));

    await page.getByRole("button", { name: "+ フィールドを追加" }).first().click();
    await page.waitForTimeout(600);
    const picker = await text();
    if (picker.includes("種類を選ぶ") && picker.includes("リッチエディタ")) note("種類のパレットが出る");
    else fail("種類のパレットが出る", picker.replace(/\s+/g, " ").slice(0, 160));
  } else {
    fail("スキーマの行が掴める形で出る", `${order.length} 行`);
  }

  // 14. 自分（PAT）
  await page.goto(base + "/account", { waitUntil: "networkidle" });
  await waitForText("Personal Access Token", "アカウントの画面が描ける");

  // 15. プロジェクトと MCP
  await page.goto(base + "/p/default/settings/project", { waitUntil: "networkidle" });
  await waitForText("AI からつなぐ", "プロジェクトと MCP の画面が描ける");

  // 16. 監査ログ（一覧と件数）
  await page.goto(base + "/p/default/settings/audit", { waitUntil: "networkidle" });
  await waitForText("監査ログ", "監査ログの画面が描ける");
  await waitForText(" 件", "監査ログに件数の文が出る");

} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 300));
} finally {
  await browser.close();
  // **作った物を片付ける。** 煙テストは手元の DB を使うので、
  // 残すと見本のコンテンツに smoke-test が積み上がる（実際に積み上がった）。
  try {
    const admin = "http://localhost:8080/p/default/admin/graphql";
    const gql = async (query) =>
      (
        await fetch(admin, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
          body: JSON.stringify({ query }),
        })
      ).json();
    const types = await gql(`query T { contentTypes { id apiId } }`);
    const blogs = (types.data?.contentTypes ?? []).find((t) => t.apiId === "blogs");
    if (blogs) {
      const list = await gql(`query E { entries(typeId: "${blogs.id}", first: 200) { nodes { id fields } } }`);
      for (const node of list.data?.entries?.nodes ?? []) {
        if (/^smoke-(test|rich)/.test(node.fields?.title ?? "")) await gql(`mutation D { deleteEntry(id: "${node.id}") }`);
      }
    }
  } catch (error) {
    console.error("片付けに失敗:", String(error).slice(0, 200));
  }
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.error("\n" + problems.join("\n"));
  console.error(`\n${problems.length} 件の問題`);
  process.exit(1);
}
console.log("\n問題なし");
