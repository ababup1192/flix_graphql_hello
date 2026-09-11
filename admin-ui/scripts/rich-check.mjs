// 本文の飾りを 1 つずつ「使う → 下書き保存 → CMS から読み直して残っている」まで確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/rich-check.mjs
// 見る物:
//   1. 下線（underline の mark。「…」に畳んだ物）
//   2. 表（table / tableRow / tableHeader / tableCell）と、行と列の足し引き
//   3. 画像の代替テキスト
//   4. 入れ子（表 in 表・上付き＋下付き）が作れない事と、CMS が断る事
//   4d.「+」と `/` の一覧から埋め込み（embed / linkCard）を入れられる
//   4d2. 浮く帯の数式で文中の数式（math の mark）、「+」の一覧の「数式」でブロックの数式（mathBlock）
//   4f. すべての帯とすべての浮く面（横断。部品は `web/ui.ts`）
//   4g. ブロックの中の全選択がそのブロックの中だけに閉じる
//   4h. ファイル名の拡張子から言語が入る
//   4i. ツールバーが本文の枠の中で上に貼り付く
//   4j. ヘッダが 6 個・浮く帯が 6 個 +「…」で、「…」が開いて中の物が効く（案 D）
//   4k. `` `x` `` が前の 1 文字を巻き込まない / バッククォート 1 つでは変わらない
//   4l. 入力規則の一覧（記法 → 付くマーク）。記号が重なる組で片方が片方を食わない
//   4m. 掛けた装飾から抜ける道（Enter で落ちる / リストでは残る / コードと数式の → キー / Space 2 回 / ボタン）
//   5. ツールバーが幅 1440 / 1024 / 768 で溢れない

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const cms = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const problems = [];
const steps = [];

const note = (step, detail = "") => steps.push(`  OK  ${step}${detail ? " — " + detail : ""}`);
const fail = (step, detail) => problems.push(`  NG  ${step} — ${detail}`);
const check = (ok, step, detail) => (ok ? note(step) : fail(step, detail));

// **型の id は seed のたびに変わる。** 焼き付けず apiId から引く。
const blogTypeId = await fetch(`${cms}/p/default/admin/graphql`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
  body: JSON.stringify({ query: `query { contentTypes { id apiId } }` }),
})
  .then((response) => response.json())
  .then((answer) => (answer.data?.contentTypes ?? []).find((type) => type.apiId === "blogs")?.id ?? "");

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

page.on("pageerror", (error) => problems.push(`  NG  JS の例外 — ${String(error).slice(0, 200)}`));
page.on("console", (message) => {
  if (message.type() === "error") problems.push(`  NG  コンソールのエラー — ${message.text().slice(0, 200)}`);
});

const docOf = () => page.evaluate(() => document.querySelector("tiptap-editor")?.getAttribute("doc") ?? "");

// 今出ている帯 1 つの中身。
//
// **画像の帯は image の node ごとに 1 つずつ作られていて、選んでいない物は hidden で隠れている。**
// `.tt-image-bar .tt-image-tool` を全部集めると、3 枚並べた gallery ではボタンが 3 組に重なる。
// 出ている帯が 1 つだけである事も一緒に見る（2 つ出ていたら帯を作る所が二重に走っている）。
const openBars = () =>
  page.evaluate(() =>
    [...document.querySelectorAll(".tt-image-bar")]
      .filter((bar) => !bar.hidden && bar.offsetParent !== null)
      .map((bar) => [...bar.querySelectorAll(".tt-image-tool")].filter((tool) => !tool.hidden).map((tool) => tool.getAttribute("aria-label")).join("/"))
  );
const openBar = async () => {
  const bars = await openBars();
  return bars.length === 1 ? bars[0] : `帯が ${bars.length} つ出ています: ${JSON.stringify(bars)}`;
};

// doc の中の imageItem を順に。**画像の attrs もキャプションも imageItem が持つ**
// （`image` は入れ物で attrs を持たない。`docs/design/richtext-note-style.md` 3）。
function itemsOf(doc) {
  const out = [];
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.type === "imageItem") out.push(node);
    for (const child of node.content ?? []) walk(child);
  };
  walk(doc);
  return out;
}

function types(doc) {
  const out = new Set();
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.type) out.add(node.type);
    for (const mark of node.marks ?? []) out.add("mark:" + mark.type);
    for (const child of node.content ?? []) walk(child);
  };
  walk(doc);
  return out;
}

async function openNew(title) {
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  await page.locator("input").first().fill(title);
  await page.locator("tiptap-editor .tt-body").click();
}

// 道具を 1 つ使う。**役割で 3 か所に分かれている**（`docs/design/toolbar-split-mock.html` の案 D）:
// ヘッダは押すだけで入る 6 個、浮く帯は文字に掛ける 6 個 +「…」、ブロックは「+」の一覧。
//
// 「…」と帯の物は**文字を選んでいないと押せない**（帯が出ない）。呼ぶ前に選んでおく。
const FOLDED = new Set(["下線", "蛍光ペン", "上付き", "下付き"]);
const IN_BUBBLE = new Set(["太字", "斜体", "打ち消し", "コード（文の中）", "数式（文の中）", "リンク"]);
// ヘッダから外した物と、「+」の一覧でのその名前。
// **画像は外さない**（書くたびに使うのでヘッダに残す）。「+」の一覧にも同じ口がある。
const IN_PLUS = { コードブロック: "コード", 区切り線: "区切り線", 表: "表", 引用: "引用", チェックリスト: "チェックリスト" };

async function use(title) {
  if (FOLDED.has(title)) {
    await page.locator(".tt-bubble .tt-more").click();
    await page.waitForTimeout(250);
    await page.locator(`.tt-more-item[data-more="${title}"]`).click();
    await page.waitForTimeout(250);
    return;
  }
  if (IN_BUBBLE.has(title)) {
    await page.locator(`.tt-bubble-tool[data-bubble="${title}"]`).click();
    await page.waitForTimeout(200);
    return;
  }
  if (IN_PLUS[title]) {
    await page.locator(".tt-plus").click();
    await page.waitForTimeout(250);
    await page.locator(".tt-blocks-item", { hasText: IN_PLUS[title] }).first().click();
    await page.waitForTimeout(300);
    return;
  }
  await page.locator(`.tt-tool[title="${title}"]`).click();
  await page.waitForTimeout(200);
}

async function save(step) {
  await page.getByRole("button", { name: "下書き保存" }).click();
  await page.waitForTimeout(1800);
  const body = (await page.textContent("body")) ?? "";
  check(body.includes("保存済み"), step, body.replace(/\s+/g, " ").slice(0, 240));
}

const marker = Date.now();

try {
  // 1. 下線
  await openNew(`rich-underline ${marker}`);
  await page.keyboard.type("したせん");
  for (let i = 0; i < 4; i += 1) await page.keyboard.press("Shift+ArrowLeft");
  check((await page.locator('.tt-tool[title="下線"]').count()) === 0, "下線はヘッダに出さない（帯の「…」に畳む）", "出ています");
  await use("下線");
  check(types(JSON.parse((await docOf()) || "{}")).has("mark:underline"), "下線の mark が入る", (await docOf()).slice(0, 200));
  await page.locator(".tt-bubble .tt-more").click();
  await page.waitForTimeout(250);
  check(
    await page.locator('.tt-more-item[data-more="下線"]').evaluate((el) => el.classList.contains("is-on")),
    "「…」の中の下線に印が付く",
    "付きません"
  );
  await page.keyboard.press("Escape");
  await page.waitForTimeout(250);
  await save("下線を入れた下書きが保存できる");

  // 2. 表
  await openNew(`rich-table ${marker}`);
  await page.keyboard.type("表のテスト");
  await page.keyboard.press("Enter");
  check((await page.locator('.tt-tool[title="表"]').count()) === 0, "表はヘッダに出さない（「+」の一覧だけ）", "出ています");
  check((await page.locator('.tt-tool[title="画像"]').count()) === 1, "画像はヘッダに残す", `${await page.locator('.tt-tool[title="画像"]').count()} 個`);
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  check((await page.locator(".tt-size-cell").count()) === 64, "大きさを升目で選べる", `${await page.locator(".tt-size-cell").count()} 升`);
  // 3 行 × 4 列（升目の 3 行目 4 列目）
  await page.locator(".tt-size-cell").nth(2 * 8 + 3).click();
  await page.waitForTimeout(700);
  const withTable = types(JSON.parse((await docOf()) || "{}"));
  check(withTable.has("table") && withTable.has("tableRow"), "表が入る", [...withTable].join(","));
  check(withTable.has("tableHeader"), "見出しの行が入る", [...withTable].join(","));
  check((await page.locator(".tt-body table").count()) === 1, "表が描かれる", "出ません");
  check((await page.locator(".tt-body table tr").count()) === 3, "選んだ行の数になる", `${await page.locator(".tt-body table tr").count()} 行`);
  check((await page.locator(".tt-body table tr").first().locator("th, td").count()) === 4, "選んだ列の数になる", "違います");

  await page.locator(".tt-body table th, .tt-body table td").first().click();
  for (const letter of ["あ", "い", "う", "え"]) {
    await page.keyboard.type(letter);
    await page.keyboard.press("Tab");
  }
  await page.locator(".tt-body table th, .tt-body table td").first().click();
  await page.waitForTimeout(400);

  // 表の帯が表の上に出る
  const bar = page.locator(".tt-tablebar");
  check((await bar.count()) === 1, "表の上に帯が出る", `${await bar.count()} 個`);
  const barButtons = await page.locator(".tt-tablebar-button").evaluateAll((els) => els.map((el) => el.title));
  check(
    barButtons.join("/") === "大きさを変える/左に寄せる/中央に寄せる/右に寄せる/表を消す",
    "帯は大きさ・寄せ 3 つ・ゴミ箱の順に並ぶ",
    barButtons.join("/")
  );
  check((await page.locator(".tt-grip").count()) === 0, "古い掴みは出ない", `${await page.locator(".tt-grip").count()} 個`);
  const barAbove = await page.evaluate(() => {
    const box = document.querySelector(".tt-tablebar").getBoundingClientRect();
    const at = document.querySelector(".tt-body table").getBoundingClientRect();
    return Math.abs(box.left - at.left) < 4 && box.bottom <= at.top + 4;
  });
  check(barAbove, "帯が表の真上に付く", "ずれています");

  // 掴みは行と列の端に出る
  check((await page.locator(".tt-handle-col").count()) === 4, "列の掴みが列の数だけ出る", `${await page.locator(".tt-handle-col").count()} 個`);
  check((await page.locator(".tt-handle-row").count()) === 3, "行の掴みが行の数だけ出る（見出しも入る）", `${await page.locator(".tt-handle-row").count()} 個`);
  const fit = await page.evaluate(() => {
    const handles = Array.from(document.querySelectorAll(".tt-handle-col")).map((el) => el.getBoundingClientRect());
    const cells = Array.from(document.querySelectorAll(".tt-body table tr:first-child th, .tt-body table tr:first-child td")).map((el) => el.getBoundingClientRect());
    return handles.every((handle, i) => cells[i] && Math.abs(handle.width - cells[i].width) <= 3 && Math.abs(handle.left - cells[i].left) <= 3);
  });
  check(fit, "列の掴みが列の幅と揃う", "ずれています");

  // 寄せは列全体に効く
  await page.locator('.tt-tablebar-button[title="中央に寄せる"]').click();
  await page.waitForTimeout(500);
  const centered = JSON.parse((await docOf()) || "{}");
  const column = JSON.stringify(centered).split('"align":"center"').length - 1;
  check(column === 3, "寄せが列全体（3 行）に付く", `${column} 個`);

  // 掴んで列を入れ替える
  const headings = () => page.locator(".tt-body table tr:first-child th, .tt-body table tr:first-child td").allTextContents();
  const before = (await headings()).join("/");
  const spot = await page.evaluate(() => {
    const at = Array.from(document.querySelectorAll(".tt-handle-col")).map((el) => el.getBoundingClientRect());
    // 真ん中ちょうどでは入れ替わらない（跨いだ分だけ数えるため）。少し越える。
    return { from: { x: at[0].left + at[0].width / 2, y: at[0].top + 5 }, to: { x: at[1].left + at[1].width / 2 + 6, y: at[1].top + 5 } };
  });
  await page.mouse.move(spot.from.x, spot.from.y);
  await page.mouse.down();
  await page.mouse.move(spot.to.x, spot.to.y, { steps: 10 });
  check((await page.locator(".tt-move-line").count()) === 1, "動かしている間に落ちる境目の線が出る");
  await page.mouse.up();
  await page.waitForTimeout(500);
  const after = (await headings()).join("/");
  check(before === "あ/い/う/え" && after === "い/あ/う/え", "掴んで列を入れ替えられる", `${before} → ${after}`);
  await save("表を入れた下書きが保存できる");

  // 表から離れると消える
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.mouse.move(20, 20);
  await page.waitForTimeout(400);
  check((await page.locator(".tt-tablebar").count()) === 0, "表を触っていない時は帯が出ない", `${await page.locator(".tt-tablebar").count()} 個`);
  await page.locator(".tt-body table").hover();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-tablebar").count()) > 0, "表にマウスを乗せると帯が出る", "出ません");

  // 2b. 列が多い表・長い文字でも本文の枠からはみ出さない
  await openNew(`rich-table-wide ${marker}`);
  await page.keyboard.press("Enter");
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(1 * 8 + 7).click();
  await page.waitForTimeout(600);
  await page.locator(".tt-body table th, .tt-body table td").first().click();
  await page.keyboard.type("とても長い日本語のセルの中身です。折り返して読めるはずです。");
  await page.keyboard.press("Tab");
  await page.keyboard.type("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  await page.waitForTimeout(500);
  for (const width of [1440, 1024, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    const box = await page.evaluate(() => {
      const wrap = document.querySelector(".tt-body .tableWrapper");
      const body = document.querySelector(".tt-body");
      return {
        wrapRight: Math.round(wrap.getBoundingClientRect().right),
        bodyRight: Math.round(body.getBoundingClientRect().right),
        scrolls: wrap.scrollWidth > wrap.clientWidth,
        page: document.documentElement.scrollWidth,
        view: window.innerWidth,
      };
    });
    check(box.wrapRight <= box.bodyRight + 1, `幅 ${width} で表が本文の枠を越えない`, `表 ${box.wrapRight} > 本文 ${box.bodyRight}`);
    check(box.page <= box.view + 1, `幅 ${width} でページが横スクロールしない`, `${box.page} > ${box.view}`);
    note(`幅 ${width} の表`, box.scrolls ? "入れ物の中で横スクロール" : "枠に収まる");
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await save("列の多い表の下書きが保存できる");

  // 2c. コードブロックの下の帯（ファイル名 / 言語）と、左の行番号（強調行）
  await openNew(`rich-codefile ${marker}`);
  await page.keyboard.press("Enter");
  await use("コードブロック");
  await page.waitForTimeout(500);
  await page.keyboard.type("const a = 1;");
  await page.waitForSelector(".tt-code pre", { timeout: 5000 });
  await page.waitForTimeout(300);
  const codeAt = (attr) =>
    docOf().then(
      (raw) => (JSON.parse(raw || "{}").content ?? []).find((node) => node.type === "codeBlock")?.attrs?.[attr]
    );
  // 帯はコードの下（note と同じ）
  const barBox = await page.evaluate(() => {
    const pre = document.querySelector(".tt-code pre");
    const bar = document.querySelector(".tt-code-bar");
    return { pre: pre?.getBoundingClientRect().bottom ?? 0, bar: bar?.getBoundingClientRect().top ?? 0 };
  });
  check(barBox.bar >= barBox.pre - 1, "言語とファイル名の帯がコードの下にある", JSON.stringify(barBox));

  const file = page.locator(".tt-code-file").first();
  check((await file.count()) === 1, "コードブロックにファイル名の入力がある", `${await file.count()} 個`);
  await file.fill("src/main.ts");
  await file.press("Enter");
  await page.waitForTimeout(600);
  check((await codeAt("fileName")) === "src/main.ts", "ファイル名が codeBlock の attrs に入る", JSON.stringify(await codeAt("fileName")));
  // CMS が受けない形はその場で断る
  await file.fill('bad name<>"');
  await file.press("Enter");
  await page.waitForTimeout(500);
  check(await file.evaluate((el) => el.classList.contains("is-bad")), "受けない形のファイル名に印が付く", "付きません");
  check((await codeAt("fileName")) == null, "受けない形は doc に入らない", JSON.stringify(await codeAt("fileName")));
  await file.fill("src/main.ts");
  await file.press("Enter");
  await page.waitForTimeout(400);

  // 強調行は左の行番号を押して選ぶ（帯に欄は置かない）
  check((await page.locator(".tt-code-lines").count()) === 0, "帯に強調行の入力は無い", "残っています");
  await page.locator(".tt-code pre").first().click();
  await page.keyboard.press("End");
  await page.keyboard.type("\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;");
  await page.waitForTimeout(500);
  const numbers = page.locator(".tt-code-line");
  check((await numbers.count()) === 5, "行番号が行の数だけ出る", `${await numbers.count()} 個`);
  check((await numbers.allTextContents()).join(",") === "1,2,3,4,5", "行番号は 1 から並ぶ", (await numbers.allTextContents()).join(","));
  await numbers.nth(0).click();
  await page.waitForTimeout(400);
  check((await codeAt("highlightLines")) === "1", "行番号を押すとその行が強調に入る", JSON.stringify(await codeAt("highlightLines")));
  check((await page.locator(".tt-code-band").count()) === 1, "強調した行に地の帯が出る", `${await page.locator(".tt-code-band").count()} 本`);
  await numbers.nth(2).click();
  await page.waitForTimeout(300);
  await numbers.nth(4).click({ modifiers: ["Shift"] });
  await page.waitForTimeout(400);
  check((await codeAt("highlightLines")) === "1,3-5", "Shift で押すと範囲が強調に入る", JSON.stringify(await codeAt("highlightLines")));
  await numbers.nth(0).click();
  await page.waitForTimeout(400);
  check((await codeAt("highlightLines")) === "3-5", "もう一度押すと解除できる", JSON.stringify(await codeAt("highlightLines")));
  const linedUp = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(".tt-code-line")).map((el) => el.getBoundingClientRect());
    const bands = Array.from(document.querySelectorAll(".tt-code-band")).map((el) => el.getBoundingClientRect());
    return bands.length > 0 && bands.every((band) => rows.some((row) => Math.abs(row.top - band.top) < 2));
  });
  check(linedUp, "強調の帯が行番号と縦で揃う", "ずれています");

  // 言語は打って絞る。候補は正式名 + 別名 + 色の印、決めた後は整った名前
  const lang = page.locator(".tt-code-lang").first();
  await lang.click();
  await lang.fill("c++");
  await page.waitForTimeout(400);
  const rows = await page.locator(".tt-code-item").allTextContents();
  check(rows.length === 1 && rows[0] === "CPcppc++, cc", "別名は正式名の行に添えて出る", rows.slice(0, 3).join(" / "));
  check(
    await page
      .locator(".tt-code-item .tt-code-mark")
      .first()
      .evaluate((el) => getComputedStyle(el).backgroundColor !== "rgba(0, 0, 0, 0)"),
    "候補の印に色が付く",
    "透明のままです"
  );
  await lang.press("Enter");
  await page.waitForTimeout(1200);
  check((await codeAt("language")) === "cpp", "別名で選んでも doc には正の名前が入る", JSON.stringify(await codeAt("language")));
  check((await lang.inputValue()) === "C++", "決めた後は整った名前が出る", await lang.inputValue());
  check((await page.locator(".tt-body pre code span").count()) > 0, "選んだ言語で色が付く", "色の span がありません");

  // 帯の余白は打てない（contenteditable="false"）
  const barGap = await page.locator(".tt-code-bar").first().boundingBox();
  await page.mouse.click(barGap.x + barGap.width / 2, barGap.y + barGap.height / 2);
  await page.keyboard.type("aaaa");
  await page.waitForTimeout(400);
  check(
    !(await page.locator(".tt-code-bar").first().innerText()).includes("aaaa"),
    "帯の余白を押して打っても何も入らない",
    await page.locator(".tt-code-bar").first().innerText()
  );

  // 焦点が離れると帯だけが残る（placeholder は消える）
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.waitForTimeout(500);
  check(
    await page.locator(".tt-code").first().evaluate((el) => el.classList.contains("is-idle")),
    "焦点が外れると帯の placeholder が消える",
    "is-idle が付きません"
  );
  await save("ファイル名付きのコードブロックが保存できる");

  // 3. 画像の代替テキスト
  await openNew(`rich-caption ${marker}`);
  await use("画像");
  await page.waitForTimeout(900);
  await page.locator(".fixed .grid button").nth(0).click();
  await page.getByRole("button", { name: /本文に挿入/ }).click();
  await page.waitForTimeout(700);
  const altBox = page.locator(".tt-image-alt").first();
  check((await page.locator(".tt-image.is-active .tt-image-caption").count()) === 1, "画像を選ぶとキャプションの figcaption が出る", `${await page.locator(".tt-image.is-active .tt-image-caption").count()} 個`);
  check(
    (JSON.parse((await docOf()) || "{}").content ?? []).some((node) => node.type === "image" && !node.attrs && node.content?.[0]?.type === "imageItem"),
    "1 枚でも image の中に imageItem が 1 つ（image に attrs は無い）",
    (await docOf()).slice(0, 300),
  );
  // 画像の帯は画像を押して node ごと選んだ時だけ。リンク / ALT / 縮小 / 配置 / 削除 の 5 つ（単独の画像。横に並べるは隣が画像の時だけ）
  // 画像を node ごと選ぶ（帯は node ごと選んだ時だけ出る）。
  const selectImage = async () => {
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = -1;
      editor.state.doc.descendants((node, pos) => { if (node.type.name === "imageItem" && at < 0) at = pos; });
      editor.chain().focus().setNodeSelection(at).run();
    });
    await page.waitForTimeout(300);
  };
  await selectImage();
  const imageBar = await openBar();
  check(imageBar === "リンク/代替テキスト/縮小/配置/削除", "画像の帯は リンク / ALT / 縮小 / 配置 / 削除 の順に並ぶ", imageBar);
  // 配置を押すと帯が 左 / 中央 / 右 の 3 つに入れ替わり、1 つ押すと align を書いて元の帯に戻る
  await page.locator('.tt-image-tool[title="配置"]').first().click();
  await page.waitForTimeout(200);
  const alignBar = await page.locator(".tt-image-bar .tt-image-tool").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(alignBar.join("/") === "左に寄せる/中央に寄せる/右に寄せる", "配置を押すと帯が 左 / 中央 / 右 に入れ替わる", alignBar.join("/"));
  await page.locator('.tt-image-tool[title="左に寄せる"]').first().click();
  await page.waitForTimeout(400);
  const aligned = itemsOf(JSON.parse((await docOf()) || "{}"))[0];
  check(aligned?.attrs?.align === "left", "左に寄せる で align=left が入る", JSON.stringify(aligned?.attrs ?? {}));
  check((await page.locator('.tt-image-tool[title="配置"]').count()) === 1, "配置を選ぶと元の帯に戻る");
  await page.locator('.tt-image-tool[title="配置"]').first().click();
  await page.locator('.tt-image-tool[title="中央に寄せる"]').first().click();
  await page.waitForTimeout(300);
  // キャプションは中身（text + marks）。打つと content に入り、attrs.caption は出ない
  await page.locator(".tt-image.is-active .tt-image-caption").click();
  await page.keyboard.type("きゃぷしょん");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  const withCaption = itemsOf(JSON.parse((await docOf()) || "{}"))[0];
  check(withCaption?.content?.[0]?.text === "きゃぷしょん" && withCaption?.attrs?.caption === undefined, "キャプションが imageItem の content に入る（attrs.caption は出ない）", JSON.stringify(withCaption ?? {}));
  check(itemsOf(JSON.parse((await docOf()) || "{}")).length === 1 && withCaption?.content?.length === 1, "キャプションの中の Enter は何もしない", JSON.stringify(withCaption?.content ?? []));
  // キャプションの中では画像の帯は出ず、キャプションの上に 太字 / 打ち消し / リンク の 3 つ
  check(await page.locator(".tt-image .tt-image-bar").first().isHidden(), "キャプションを打っている間は画像の帯が出ない");
  const captionBar = await page.locator(".tt-bubble-caption button").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(captionBar.join("/") === "太字/打ち消し/リンク" && (await page.locator(".tt-bubble-caption").isVisible()), "キャプションの帯は 太字 / 打ち消し / リンク の 3 つ", captionBar.join("/"));
  // キャプションから上下の矢印で前後の行へ出られる
  for (const [key, where] of [["ArrowUp", "上"], ["ArrowDown", "下"]]) {
    await page.locator(".tt-image .tt-image-caption").first().click();
    await page.waitForTimeout(200);
    await page.keyboard.press(key);
    await page.waitForTimeout(300);
    const at = await page.evaluate(() => {
      const node = window.getSelection()?.anchorNode;
      const el = node?.nodeType === 3 ? node.parentElement : node;
      return el?.closest?.(".tt-body") ? (el.tagName ?? "") : "外";
    });
    check(at === "P", `キャプションから ${key} で${where}の行へ出る`, `カーソルの親 ${at}`);
    await page.keyboard.type(where);
    await page.waitForTimeout(200);
  }
  // 代替テキストは「ALT」を押すと帯が 欄 + 適用 + × に入れ替わり、Enter / 適用で書く
  await selectImage();
  await page.locator('.tt-image-tool[title="代替テキスト"]').first().click();
  await page.waitForTimeout(200);
  check((await altBox.count()) === 1 && (await altBox.evaluate((el) => document.activeElement === el)), "ALT を押すと帯が代替テキストの欄に入れ替わり、焦点が入る", `${await altBox.count()} 個`);
  await altBox.fill("さんぷるの代替");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  const withAlt = JSON.parse((await docOf()) || "{}");
  const image = itemsOf(withAlt)[0];
  check(image?.attrs?.alt === "さんぷるの代替", "代替テキストが imageItem の attrs に入る", JSON.stringify(image?.attrs ?? {}));
  check((await page.locator('.tt-image-tool[title="代替テキスト"]').count()) === 1, "適用の後は元の帯に戻る");

  const around = JSON.parse((await docOf()) || "{}");
  const kinds = (around.content ?? []).map((node) => node.type).join(" ");
  check(kinds.includes("paragraph image paragraph"), "画像の上下に行ができる", kinds);
  await save("代替テキスト付きの下書きが保存できる");

  // 3b. 画像を 2 枚続けて入れる
  //
  // メディアの画面を開くとエディタが焦点を失い、疑似行（`web/block-edges.ts`）が消える。
  // 選択はその行の跡＝直前の画像のキャプションに戻るので、そこへ入れると「空の textblock は
  // 入れた物で置き換える」で 1 枚目の imageItem ごと置き換わっていた（1 枚目の assetId が消えた）。
  await openNew(`rich-two-images ${marker}`);
  const insertPicked = async (nth) => {
    await use("画像");
    await page.waitForTimeout(900);
    await page.locator(".fixed .grid button").nth(nth).click();
    await page.getByRole("button", { name: /本文に挿入/ }).click();
    await page.waitForTimeout(700);
  };
  await insertPicked(0);
  const firstId = itemsOf(JSON.parse((await docOf()) || "{}"))[0]?.attrs?.assetId ?? "";
  // 画像の下（本文の枠の余白）を押して行を足す。ここで押せる状態にしないとヘッダの画像は薄いまま。
  const body = await page.locator("tiptap-editor .tt-body").boundingBox();
  await page.mouse.click(body.x + body.width / 2, body.y + body.height - 6);
  await page.waitForTimeout(300);
  await insertPicked(1);
  const twoImages = JSON.parse((await docOf()) || "{}");
  const images = (twoImages.content ?? []).filter((node) => node.type === "image");
  const items = itemsOf(twoImages);
  check(images.length === 2, "画像を 2 枚続けて入れると image が 2 つになる", `${images.length} つ: ${JSON.stringify((twoImages.content ?? []).map((node) => node.type))}`);
  check(items[0]?.attrs?.assetId === firstId && firstId !== "", "2 枚目を入れても 1 枚目の assetId が残る", `${firstId} → ${JSON.stringify(items[0]?.attrs ?? {})}`);
  check(items.every((item) => item?.attrs?.assetId), "どの imageItem も assetId を持つ（既定値に潰れない）", JSON.stringify(items.map((item) => item?.attrs ?? {})));
  await save("画像 2 枚の下書きが保存できる");

  // 4. 入れ子ができない
  await openNew(`rich-nest ${marker}`);
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(1 * 8 + 1).click();
  await page.waitForTimeout(600);
  // 引用は「+」の一覧に移ったので、セルの中では口そのものが無い（この節の最後で見る）。
  for (const title of ["箇条書き"]) {
    await page.locator(".tt-body table th").first().click();
    await page.waitForTimeout(200);
    await use(title);
    await page.waitForTimeout(400);
    const inside = (JSON.parse((await docOf()) || "{}").content ?? [])
      .flatMap((node) => (node.type === "table" ? node.content ?? [] : []))
      .flatMap((row) => row.content ?? [])
      .flatMap((cell) => (cell.content ?? []).map((child) => child.type))
      .filter((kind) => kind !== "paragraph");
    check(inside.length === 0, `表のセルに「${title}」は入らない`, inside.join(" "));
  }
  // ブロックを入れる口は「+」だけになったので、セルの中では口そのものが出ない
  // （表の中の表・セルの中のコードブロックは押せる所が無い）。
  await page.locator(".tt-body table th").first().click();
  await page.waitForTimeout(400);
  check(await page.locator(".tt-plus").isHidden(), "表のセルの中では「+」が出ない", "出ています");

  // 上付き＋下付き
  await openNew(`rich-raised ${marker}`);
  await page.keyboard.type("a");
  await page.keyboard.press("Shift+ArrowLeft");
  await page.waitForTimeout(300);
  await use("上付き");
  await use("下付き");
  await page.waitForTimeout(400);
  const raised = (JSON.parse((await docOf()) || "{}").content?.[0]?.content?.[0]?.marks ?? []).map((m) => m.type);
  check(raised.length === 1 && raised[0] === "sub", "上付きと下付きは重ならない", raised.join("+"));
  await save("上付きだけの下書きが保存できる");

  // CMS も入れ子を断る
  const send = (body) =>
    fetch(`${cms}/p/default/admin/graphql`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
      body: JSON.stringify(body),
    }).then((response) => response.json());
  const para = (text) => ({ type: "paragraph", content: [{ type: "text", text }] });
  const badDocs = {
    "表のセルの中の表": { type: "doc", content: [{ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [para("外"), { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [para("中")] }] }] }] }] }] }] },
    "引用の中の引用": { type: "doc", content: [{ type: "blockquote", content: [{ type: "blockquote", content: [para("中")] }] }] },
    "上付き＋下付き": { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "a", marks: [{ type: "sub" }, { type: "sup" }] }] }] },
  };
  for (const [name, doc] of Object.entries(badDocs)) {
    const answer = await send({
      query: `mutation m($fields: JSON!) { createEntry(typeId: "${blogTypeId}", fields: $fields) { id } }`,
      variables: { fields: { title: `nest ${marker} ${name}`, body: doc } },
    });
    const message = JSON.stringify(answer.errors ?? answer);
    check(message.includes("INVALID") || message.includes("入力"), `CMS が「${name}」を断る`, message.slice(0, 200));
  }

  // 4b. 入れた直後にカーソルが「続きを書ける所」に入る
  //
  // 中に文字を書けるブロックは中に、書けないブロック（カード・埋め込み）はその下の段落に。
  const focusOf = () =>
    page.evaluate(() => {
      const host = document.querySelector("tiptap-editor");
      const active = document.activeElement;
      const $from = host.editor.view.state.selection.$from;
      const names = [];
      for (let depth = $from.depth; depth > 0; depth -= 1) names.push($from.node(depth).type.name);
      return { dom: active ? String(active.className).split(" ")[0] : "", inside: names[0] ?? "doc", index: $from.index(0) };
    });

  // `$$` + Enter は、node view の中の TeX の欄に入る（ProseMirror の選択ではなく DOM の焦点）。
  await openNew(`rich-focus-math ${marker}`);
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  check((await focusOf()).dom === "tt-mathblock-src", "$$ の直後に TeX の欄へ入る", JSON.stringify(await focusOf()));
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);
  const mathDoc = JSON.parse((await docOf()) || "{}");
  check(JSON.stringify(mathDoc).includes('"tex":"E = mc^2"'), "$$ の直後に打った TeX が数式に入る", JSON.stringify(mathDoc).slice(0, 200));

  // 4c. 数式は「普段は組版だけ、箱のどこを押しても TeX、掴みで選ぶと削除の帯」
  //     （docs/design/richtext-math-ui.md）
  const mathSrc = page.locator(".tt-mathblock-src").first();
  const mathOut = page.locator(".tt-mathblock-out").first();
  await page.locator("tiptap-editor .tt-body p").first().click();
  await page.waitForTimeout(300);
  check(await mathSrc.isHidden(), "普段は TeX の欄が隠れている", "見えています");
  check((await page.locator(".tt-mathblock .katex").count()) > 0, "普段は組版された数式が出る", "出ません");
  check(
    await mathSrc.evaluate((el) => getComputedStyle(el).resize === "none"),
    "TeX の欄は掴んで伸ばせない",
    await mathSrc.evaluate((el) => getComputedStyle(el).resize)
  );

  await mathOut.click();
  await page.waitForTimeout(300);
  check(await mathSrc.isVisible(), "組版を押すと TeX の欄が開く", "開きません");
  check((await focusOf()).dom === "tt-mathblock-src", "組版を押すと TeX の欄へ焦点が入る", JSON.stringify(await focusOf()));

  // 組版の面の外（箱の左端の余白と、欄との隙間）を押しても同じように開く
  const mathBox = page.locator(".tt-mathblock").first();
  for (const [name, spot] of [["箱の左端", { x: 3, y: 0.5 }], ["箱の右端", { x: -3, y: 0.5 }]]) {
    await page.locator("tiptap-editor .tt-body p").first().click();
    await page.waitForTimeout(250);
    const box = await mathBox.boundingBox();
    await page.mouse.click(spot.x < 0 ? box.x + box.width + spot.x : box.x + spot.x, box.y + box.height * spot.y);
    await page.waitForTimeout(300);
    check(await mathSrc.isVisible(), `${name}を押しても TeX の欄が開く`, "開きません");
  }

  // TeX の欄の 1 行目の ↑ で前の行へ出る（node view が鍵を食べても矢印は届く）
  await mathOut.click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-mathblock-src", "1 行目の ↑ で TeX の欄から前の行へ出る", JSON.stringify(await focusOf()));
  await mathOut.click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-mathblock-src", "最終行の ↓ で TeX の欄から次の行へ出る", JSON.stringify(await focusOf()));

  // ホバーの間だけ右上に削除が出る（案 B）
  const mathCorner = page.locator(".tt-mathblock .tt-block-corner").first();
  check((await mathCorner.count()) === 1, "数式の右上に削除が付く", `${await mathCorner.count()} 個`);
  check(
    (await mathCorner.getAttribute("aria-label")) === "削除",
    "ホバーの削除の aria-label は「削除」",
    String(await mathCorner.getAttribute("aria-label"))
  );
  // 触っていない間は見えない（押した直後は指が箱の上に残っているので、先に外へ出す）
  await page.mouse.move(5, 5);
  await page.waitForTimeout(300);
  check(
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity === "0"),
    "触っていない間は右上の削除が見えない",
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity)
  );
  await mathBox.hover();
  await page.waitForTimeout(300);
  check(
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity === "1"),
    "ホバーすると右上の削除が出る",
    await mathCorner.evaluate((el) => getComputedStyle(el).opacity)
  );
  // 右上の削除で数式が消え、段落に戻る
  await mathCorner.click();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "右上の削除で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  await page.mouse.move(5, 5);

  // もう一度 $$ で入れ直して、選んだ状態の帯を見る
  // （帯は箱の 76px 上に浮くので、数式が本文の先頭だと枠の外に出て押せない。1 行前に置く）
  await page.keyboard.type("すうしきのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(500);
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);
  // 欄の中の Esc は欄を閉じて数式を選んだ状態にする（上に削除だけの帯が出る）
  await page.keyboard.press("Escape");
  await page.waitForTimeout(400);
  check(
    (await page.locator(".tt-mathblock.ProseMirror-selectednode").count()) === 1,
    "欄の中の Esc で数式を選んだ状態になる",
    `${await page.locator(".tt-mathblock.ProseMirror-selectednode").count()} 個`
  );
  const mathBar = await page.locator(".tt-mathblock .tt-image-bar .tt-image-tool").evaluateAll((els) => els.map((el) => el.getAttribute("aria-label")));
  check(mathBar.join("/") === "削除", "数式の帯は削除だけ", mathBar.join("/"));
  check(await mathSrc.isHidden(), "選んでいる間は TeX の欄を閉じる", "開いています");
  await page.locator(".tt-mathblock .tt-image-bar").first().scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await page.locator(".tt-mathblock .tt-image-tool").first().click();
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "帯の削除で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  check(
    (JSON.parse((await docOf()) || "{}").content ?? []).every((node) => node.type === "paragraph"),
    "削除した所に段落が残る",
    JSON.stringify(JSON.parse((await docOf()) || "{}")).slice(0, 200)
  );

  // 空の TeX の欄で Backspace は段落に戻す
  await openNew(`rich-math-back ${marker}`);
  await page.keyboard.type("$$");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(400);
  check((await page.locator(".tt-mathblock").count()) === 0, "空の TeX の欄の Backspace で数式が消える", `${await page.locator(".tt-mathblock").count()} 個`);
  await page.keyboard.type("もどった");
  await page.waitForTimeout(300);
  check(JSON.stringify(JSON.parse((await docOf()) || "{}")).includes("もどった"), "消した後は段落に続きが打てる", (await docOf()).slice(0, 200));

  // 引用の出典は箱の外の下の右。出典は引用の最後の子の quoteCite で、マークを掛けられる。
  // ↑ も ↓ も引用の外の行へ出る
  await openNew(`rich-quote-cite ${marker}`);
  await page.keyboard.type("いんようのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("> ひきよう");
  await page.waitForTimeout(400);
  const citeRow = page.locator(".tt-quote-cite-row").first();
  check((await page.locator(".tt-quote-cite-row").count()) === 1, "出典の行は 1 つだけ", `${await page.locator(".tt-quote-cite-row").count()} 個`);
  check((await page.locator(".tt-quote-link").count()) === 0, "出典の行に印（ボタン）は出さない", `${await page.locator(".tt-quote-link").count()} 個`);
  check(
    (await page.locator(".tt-quote-hint").first().textContent()) === "出典を入力",
    "空の出典には placeholder「出典を入力」が出る",
    String(await page.locator(".tt-quote-hint").first().textContent())
  );
  check((await page.locator("cite.tt-quote-cite").count()) === 0, "出典が空の間は quoteCite を作らない", `${await page.locator("cite.tt-quote-cite").count()} 個`);
  const citeBelow = await page.evaluate(() => {
    const box = document.querySelector(".tt-quote blockquote").getBoundingClientRect();
    const row = document.querySelector(".tt-quote-cite-row").getBoundingClientRect();
    return row.top >= box.bottom - 1 && row.right >= box.right - 4;
  });
  check(citeBelow, "出典は箱の外の下、右に出る", "箱の中か左にあります");

  // 出典の行は node view の中（contentDOM の外）にある。引用の箱の高さにこの行が入らないと、
  // 次のブロックが行の上に乗る。次に来る 5 種で、行の下端が次のブロックの上端を越えない事を測る。
  for (const [kind, node] of Object.entries({
    数式: { type: "mathBlock", attrs: { tex: "\\sum_{i=1}^{n} \\frac{x_i^2}{\\sqrt{y_i}}" } },
    段落: { type: "paragraph", content: [{ type: "text", text: "次の段落" }] },
    画像: { type: "image", attrs: { src: "https://placehold.co/600x200.png", alt: "え" } },
    コード: { type: "codeBlock", attrs: { language: "javascript" }, content: [{ type: "text", text: "const a = 1;" }] },
    引用: {
      type: "blockquote",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "つぎのいんよう" }] },
        { type: "quoteCite", content: [{ type: "text", text: "つぎのしゅってん" }] },
      ],
    },
  })) {
    for (const cite of ["しゅってん", null]) {
      await page.evaluate(
        ([cite, node]) => {
          document.querySelector("tiptap-editor").editor.commands.setContent({
            type: "doc",
            content: [
              {
                type: "blockquote",
                content: [
                  { type: "paragraph", content: [{ type: "text", text: "ひきよう" }] },
                  ...(cite ? [{ type: "quoteCite", content: [{ type: "text", text: cite }] }] : []),
                ],
              },
              node,
              { type: "paragraph", content: [{ type: "text", text: "おわり" }] },
            ],
          });
        },
        [cite, node]
      );
      await page.waitForTimeout(500);
      const gap = await page.evaluate(() => {
        const quote = document.querySelector("tiptap-editor .tt-body .tt-quote");
        // 出典は箱に重ねて置くので、下端は出典（あれば）か、場所を空けている行で測る。
        const above = quote.querySelector("blockquote > cite") ?? quote.querySelector(".tt-quote-cite-row");
        return above.getBoundingClientRect().bottom - quote.nextElementSibling.getBoundingClientRect().top;
      });
      check(gap <= 0, `引用の出典の行が次のブロック（${kind}・出典${cite ? "あり" : "なし"}）に重ならない`, `${gap.toFixed(1)}px 食い込んでいます`);
    }
  }

  await openNew(`rich-quote-cite2 ${marker}`);
  await page.keyboard.type("> ひきよう");
  await page.waitForTimeout(400);
  await citeRow.click();
  await page.waitForTimeout(300);
  check((await focusOf()).inside === "quoteCite", "出典の行を押すと出典に焦点が入る", JSON.stringify(await focusOf()));
  await page.keyboard.type("でんき");
  await page.waitForTimeout(300);
  check(
    (await page.locator("cite.tt-quote-cite").first().textContent()) === "でんき",
    "出典に打った字が入る（本文に落ちない）",
    String(await page.locator("cite.tt-quote-cite").first().textContent())
  );
  // 出典の文字にもマークを掛けられる（帯の太字とリンク。CMS が受けるのは captionMarkNames の 5 つ）。
  await page.evaluate(() => {
    const editor = document.querySelector("tiptap-editor").editor;
    let at = null;
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name === "quoteCite") at = { from: pos + 1, to: pos + node.nodeSize - 1 };
    });
    editor.chain().focus().setTextSelection(at).run();
  });
  await page.waitForTimeout(400);
  check(await page.locator(".tt-bubble").first().isVisible(), "出典の文字を選ぶと帯が出る", "帯が出ません");
  // 出典はキャプションと同じ 1 行の文字なので、帯は 3 つ（太字 / 打ち消し / リンク）だけ。
  const citeBar = await page.locator(".tt-bubble-caption button").evaluateAll((all) => all.map((one) => one.title));
  check(
    citeBar.join("/") === "太字/打ち消し/リンク" && (await page.locator(".tt-bubble-caption").isVisible()),
    "出典の中では帯が 太字 / 打ち消し / リンク の 3 つ",
    citeBar.join("/")
  );
  check(await page.locator(".tt-bubble .tt-more").isHidden(), "出典の中では帯に「…」を出さない", "出ています");
  await page.evaluate(() => document.querySelector("tiptap-editor").editor.chain().focus().toggleBold().run());
  await page.evaluate(() => document.querySelector("tiptap-editor").editor.chain().focus().setLink({ href: "https://src.example/" }).run());
  await page.waitForTimeout(300);
  check((await page.locator("cite.tt-quote-cite strong").count()) === 1, "出典に太字が掛かる", `${await page.locator("cite.tt-quote-cite strong").count()} 個`);
  check((await page.locator("cite.tt-quote-cite a").count()) === 1, "出典にリンクが掛かる", `${await page.locator("cite.tt-quote-cite a").count()} 個`);
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).inside !== "quoteCite", "出典の ↑ で引用の外の行へ出る", JSON.stringify(await focusOf()));
  const quoteDoc = JSON.stringify(JSON.parse((await docOf()) || "{}"));
  check(quoteDoc.includes('"type":"quoteCite"'), "出典が引用の最後の子（quoteCite）に入る", (await docOf()).slice(0, 300));
  check(!quoteDoc.includes('"cite":'), "旧い attrs.cite / citeUrl は書かない", (await docOf()).slice(0, 300));
  // 出典に中身がある時は、行（node view の飾り）の上に cite が重なる。押す相手は cite。
  await page.locator("cite.tt-quote-cite").first().click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).inside !== "quoteCite", "出典の ↓ でも引用の外の行へ出る", JSON.stringify(await focusOf()));

  // 旧い形（attrs.cite / citeUrl）の doc を開くと quoteCite に写る
  await openNew(`rich-quote-legacy ${marker}`);
  await page.evaluate(() => {
    document.querySelector("tiptap-editor").setAttribute(
      "doc",
      JSON.stringify({
        type: "doc",
        content: [
          {
            type: "blockquote",
            attrs: { cite: "むかしのしゅってん", citeUrl: "https://src.example/" },
            content: [{ type: "paragraph", content: [{ type: "text", text: "ふるいいんよう" }] }],
          },
        ],
      })
    );
  });
  await page.waitForTimeout(600);
  check(
    (await page.locator("cite.tt-quote-cite a").first().textContent()) === "むかしのしゅってん",
    "旧い attrs.cite が出典（quoteCite）に写り、citeUrl がリンクになる",
    String(await page.locator("cite.tt-quote-cite").first().textContent())
  );

  // コードブロックのファイル名の欄も、↑↓ で前後の行へ出る
  await openNew(`rich-code-file ${marker}`);
  await page.keyboard.type("こーどのまえ");
  await page.keyboard.press("Enter");
  await page.keyboard.type("```");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  await page.keyboard.type("let x = 1");
  await page.locator(".tt-code-file").first().click();
  await page.waitForTimeout(300);
  check((await focusOf()).dom === "tt-code-file", "ファイル名の欄へ入る", JSON.stringify(await focusOf()));
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-code-file", "ファイル名の欄の ↑ で前の行へ出る", JSON.stringify(await focusOf()));
  await page.locator(".tt-code-file").first().click();
  await page.waitForTimeout(300);
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check((await focusOf()).dom !== "tt-code-file", "ファイル名の欄の ↓ で次の行へ出る", JSON.stringify(await focusOf()));

  // ``` + Enter はコードブロックの中。
  await openNew(`rich-focus-code ${marker}`);
  await page.keyboard.type("```");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  check((await focusOf()).inside === "codeBlock", "``` の直後にコードブロックの中へ入る", JSON.stringify(await focusOf()));

  // 引用は中の段落。
  await openNew(`rich-focus-quote ${marker}`);
  await page.keyboard.type("> ");
  await page.waitForTimeout(400);
  check((await focusOf()).inside === "paragraph", "> の直後に引用の中へ入る", JSON.stringify(await focusOf()));

  // 表は最初の升。
  await openNew(`rich-focus-table ${marker}`);
  await use("表");
  await page.waitForSelector(".tt-size-grid", { timeout: 4000 });
  await page.locator(".tt-size-cell").nth(2 * 8 + 2).click();
  await page.waitForTimeout(500);
  check((await focusOf()).inside === "paragraph", "表を入れた直後に升の中へ入る", JSON.stringify(await focusOf()));

  // URL 1 つを貼って作るカードは、中に書けないのでその下の段落へ。
  await openNew(`rich-focus-card ${marker}`);
  await page.evaluate(() => {
    const view = document.querySelector("tiptap-editor").editor.view;
    const data = new DataTransfer();
    data.setData("text/plain", "https://example.com/focus");
    view.dom.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  });
  await page.waitForTimeout(500);
  const cardAt = await focusOf();
  check(cardAt.inside === "paragraph" && cardAt.index === 1, "URL を貼った直後にカードの下の段落へ入る", JSON.stringify(cardAt));
  await page.keyboard.type("つづき");
  await page.waitForTimeout(400);
  const cardDoc = JSON.parse((await docOf()) || "{}");
  check(
    (cardDoc.content ?? []).map((node) => node.type).join(",") === "linkCard,paragraph" && JSON.stringify(cardDoc).includes("つづき"),
    "カードの後にそのまま続きが打てる",
    JSON.stringify(cardDoc).slice(0, 200)
  );

  // 4d.「+」と `/` の一覧から埋め込みを入れられる（URL の欄が出て、提供元で embed / linkCard に分かれる）
  for (const way of [
    { name: "「+」", bySlash: false, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", want: "embed" },
    { name: "「+」", bySlash: false, url: "https://example.com/rich-check", want: "linkCard" },
    { name: "`/`", bySlash: true, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", want: "embed" },
  ]) {
    await openNew(`rich-embed ${way.want} ${way.bySlash ? "slash" : "plus"} ${marker}`);
    if (way.bySlash) {
      await page.keyboard.type("/");
      await page.waitForTimeout(400);
    } else {
      await page.locator(".tt-plus").click();
      await page.waitForTimeout(300);
    }
    await page.locator(".tt-blocks-item", { hasText: "埋め込み" }).click();
    await page.waitForTimeout(400);
    const urlBox = page.locator(".tt-blocks-url");
    check((await urlBox.count()) === 1, `${way.name} の一覧の「埋め込み」で URL の欄が出る`, `${await urlBox.count()} 個`);
    if ((await urlBox.count()) !== 1) continue;
    await urlBox.fill(way.url);
    await urlBox.press("Enter");
    await page.waitForTimeout(800);
    const embedDoc = JSON.parse((await docOf()) || "{}");
    check(types(embedDoc).has(way.want), `${way.name} から ${way.url.includes("youtube") ? "YouTube" : "他"} の URL が ${way.want} になる`, JSON.stringify(embedDoc).slice(0, 200));
  }

  // 4d2. 数式は `$…$` を知らなくても入る（浮く帯の Σ と「+」の一覧の「数式」）
  await openNew(`rich-math-inline ${marker}`);
  await page.keyboard.type("速さはx");
  await page.keyboard.press("Shift+ArrowLeft");
  await page.waitForTimeout(300);
  await use("数式（文の中）");
  await page.waitForTimeout(300);
  await page.keyboard.type("E = mc^2");
  await page.waitForTimeout(400);
  const inlineDoc = JSON.parse((await docOf()) || "{}");
  check(types(inlineDoc).has("mark:math"), "浮く帯の数式で文中の数式が入る", JSON.stringify(inlineDoc).slice(0, 200));
  check(JSON.stringify(inlineDoc).includes("E = mc^2"), "文中の数式にそのまま TeX が打てる", JSON.stringify(inlineDoc).slice(0, 200));

  await openNew(`rich-math-block ${marker}`);
  await page.locator(".tt-plus").click();
  await page.waitForTimeout(300);
  await page.locator(".tt-blocks-item", { hasText: "数式" }).click();
  await page.waitForTimeout(500);
  const openedMath = page.locator(".tt-mathblock-src:not([hidden])");
  check((await openedMath.count()) === 1, "「+」の一覧の「数式」で TeX の欄が開く", `${await openedMath.count()} 個`);
  await page.keyboard.type("\\frac{1}{2}");
  await page.waitForTimeout(400);
  const blockDoc = JSON.parse((await docOf()) || "{}");
  check(types(blockDoc).has("mathBlock"), "+ からブロックの数式が入る", JSON.stringify(blockDoc).slice(0, 200));
  check(JSON.stringify(blockDoc).includes("\\\\frac{1}{2}"), "ブロックの数式の欄に打った TeX が入る", JSON.stringify(blockDoc).slice(0, 200));

  // 4e. 並べた画像（image > imageItem+）の下の空の段落でも「+」が本文の枠の中に出る。
  // キャプションの開閉や画像の読み込みは transaction を伴わずに高さを変えるので、
  // 一度測っただけの位置は取り残され、枠の外（下のフィールド）に出ていた。
  const galleryIds = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query { assets(first: 3) { edges { node { id } } } }` }),
  })
    .then((response) => response.json())
    .then((answer) => (answer.data?.assets?.edges ?? []).map((edge) => edge.node.id));
  if (galleryIds.length < 2) {
    fail("gallery を確かめるメディアがある", `${galleryIds.length} 個`);
  } else {
    await openNew(`rich-gallery ${marker}`);
    await page.evaluate((ids) => {
      document.querySelector("tiptap-editor").setAttribute(
        "doc",
        JSON.stringify({
          type: "doc",
          content: [
            { type: "paragraph", content: [{ type: "text", text: "まえがき" }] },
            { type: "image", content: ids.map((id) => ({ type: "imageItem", attrs: { assetId: id } })) },
            { type: "paragraph" },
          ],
        }),
      );
    }, galleryIds);
    await page.waitForTimeout(1200);
    // gallery の中のキャプションを開いてから末尾の空の段落へ移す（高さが変わる道）。
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = null;
      editor.state.doc.descendants((node, pos) => {
        if (at === null && node.type.name === "imageItem") at = pos + 1;
      });
      editor.commands.focus();
      editor.commands.setTextSelection(at);
    });
    await page.waitForTimeout(500);
    await page.evaluate(() => document.querySelector("tiptap-editor").editor.commands.focus("end"));
    await page.waitForTimeout(600);
    const plusAt = await page.evaluate(() => {
      const plus = document.querySelector(".tt-plus");
      const bodyBox = document.querySelector(".tt-body").getBoundingClientRect();
      const plusBox = plus.getBoundingClientRect();
      const editor = document.querySelector("tiptap-editor").editor;
      const paragraph = editor.view.nodeDOM(editor.state.selection.$from.before());
      const paraBox = paragraph?.getBoundingClientRect?.();
      return {
        hidden: plus.hidden,
        inside: plusBox.top >= bodyBox.top && plusBox.bottom <= bodyBox.bottom,
        off: paraBox ? Math.round(plusBox.top + plusBox.height / 2 - (paraBox.top + paraBox.height / 2)) : null,
      };
    });
    check(plusAt.hidden === false && plusAt.inside, "gallery の下の空の段落でも「+」が本文の枠の中に出る", JSON.stringify(plusAt));
    check(Math.abs(plusAt.off ?? 999) <= 4, "「+」が空の段落の高さに並ぶ", `${plusAt.off} px ずれています`);

    // 中の画像が gallery の枠からはみ出さない。
    const outs = await page.evaluate(() => {
      const box = document.querySelector(".tt-gallery").getBoundingClientRect();
      return [...document.querySelectorAll(".tt-gallery-grid .tt-image")].map((one) => Math.round(one.getBoundingClientRect().right - box.right));
    });
    check(outs.every((out) => out <= 0), "gallery の中の画像が枠に収まる", `はみ出し ${JSON.stringify(outs)}`);

    // 列を選ぶ帯は無く、列は枚数から決まる（2 枚なら 2 列、3 枚以上は 3 列で折り返す）。
    check((await page.locator(".tt-gallery-bar").count()) === 0, "列を選ぶ帯が無い");
    const columns = await page.evaluate(() => getComputedStyle(document.querySelector(".tt-gallery-grid")).gridTemplateColumns.split(" ").length);
    const wantColumns = Math.min(galleryIds.length, 3);
    check(columns === wantColumns, `${galleryIds.length} 枚の gallery は ${wantColumns} 列になる`, `${columns} 列`);

    // 並べた中の 1 枚は リンク / ALT / 削除、ぜんたいは 1 枚ずつに戻す / 削除
    //（`docs/design/richtext-gallery-flow.html` 2・3。縮小と配置はどちらにも出さない）。
    await page.locator(".tt-gallery-grid .tt-image img").first().click();
    await page.waitForTimeout(300);
    const oneBar = await openBar();
    check(oneBar === "リンク/代替テキスト/削除", "並べた中の 1 枚の帯は リンク / ALT / 削除", oneBar);

    // ぜんたいは枠の外周の余白（中の画像の外）を押して選ぶ。
    const frame = await page.locator(".tt-gallery").first().boundingBox();
    await page.mouse.click(frame.x + 4, frame.y + frame.height / 2);
    await page.waitForTimeout(300);
    const galleryBar = await openBar();
    check(galleryBar === "1 枚ずつに戻す/削除", "並べた画像ぜんたいの帯は 1 枚ずつに戻す / 削除", galleryBar);
    check((await page.locator(".tt-gallery.ProseMirror-selectednode").count()) === 1, "ぜんたいを選ぶと枠が外側に出る", `${await page.locator(".tt-gallery.ProseMirror-selectednode").count()} 個`);

    // 「1 枚ずつに戻す」で image が枚数ぶんに分かれる（帯はぜんたいの物）。
    await page.locator('.tt-image-tool[title="1 枚ずつに戻す"]').first().click();
    await page.waitForTimeout(600);
    const loosened = JSON.parse((await docOf()) || "{}").content ?? [];
    check(
      loosened.filter((node) => node.type === "image").length === galleryIds.length &&
        loosened.filter((node) => node.type === "image").every((node) => node.content?.length === 1),
      "「1 枚ずつに戻す」で image が 1 枚ずつに分かれる",
      loosened.map((node) => node.type).join(" ")
    );

    // 隣り合う 1 枚の帯には「横に並べる」が出て、押すと image 1 つに畳まれる。
    await page.locator(".tt-image img").first().click();
    await page.waitForTimeout(300);
    const rowBar = await openBar();
    check(rowBar === "リンク/代替テキスト/縮小/配置/横に並べる/削除", "隣り合う 1 枚の帯には「横に並べる」が出る", rowBar);
    await page.locator('.tt-image-tool[title="横に並べる"]').first().click();
    await page.waitForTimeout(600);
    const folded = JSON.parse((await docOf()) || "{}").content ?? [];
    check(
      folded.filter((node) => node.type === "image").length === 1 && folded.find((node) => node.type === "image")?.content?.length === galleryIds.length,
      "「横に並べる」で image 1 つに畳まれる",
      JSON.stringify(folded)
    );

    // 最後の 1 枚を消すと image ごと消える（空の image は CMS が断る）。
    await page.evaluate((ids) => {
      document.querySelector("tiptap-editor").setAttribute(
        "doc",
        JSON.stringify({
          type: "doc",
          content: [
            { type: "image", content: [{ type: "imageItem", attrs: { assetId: ids[0] } }] },
            { type: "paragraph" },
          ],
        }),
      );
    }, galleryIds);
    await page.waitForTimeout(1000);
    await page.locator(".tt-image img").first().click();
    await page.waitForTimeout(300);
    await page.locator('.tt-image-tool[title="削除"]').first().click();
    await page.waitForTimeout(600);
    check(!types(JSON.parse((await docOf()) || "{}")).has("image"), "最後の 1 枚を消すと image ごと消える", (await docOf()).slice(0, 200));

    // 旧い形（gallery と attrs.assetId の image と attrs.caption）は、読む時に新しい形へ写る。
    await page.evaluate((ids) => {
      document.querySelector("tiptap-editor").setAttribute(
        "doc",
        JSON.stringify({
          type: "doc",
          content: [
            { type: "image", attrs: { assetId: ids[0], caption: "ふるいきゃぷしょん", size: "small" } },
            { type: "gallery", attrs: { columns: 2 }, content: ids.slice(0, 2).map((id) => ({ type: "image", attrs: { assetId: id } })) },
            { type: "paragraph" },
          ],
        }),
      );
    }, galleryIds);
    await page.waitForTimeout(1200);
    const lifted = await page.evaluate(() => document.querySelector("tiptap-editor").editor.getJSON());
    const liftedImages = (lifted.content ?? []).filter((node) => node.type === "image");
    check(!JSON.stringify(lifted).includes('"gallery"'), "旧 gallery は開いた時に image に写る", JSON.stringify(lifted.content));
    check(
      liftedImages.length === 2 && liftedImages[0].content?.length === 1 && liftedImages[1].content?.length === 2,
      "旧 image は 1 枚の image > imageItem に、旧 gallery は 2 枚に写る",
      JSON.stringify(lifted.content)
    );
    check(
      liftedImages[0]?.content?.[0]?.content?.[0]?.text === "ふるいきゃぷしょん" && liftedImages[0]?.content?.[0]?.attrs?.size === "small",
      "旧 attrs.caption は imageItem の content に、attrs は imageItem に移る",
      JSON.stringify(liftedImages[0] ?? {})
    );
  }

  // 4f. 帯と浮く面の横断の確認（部品は `web/ui.ts`。`docs/design/editor-dom-parts.md`）。
  // ブロックごとに書かず、**すべての帯とすべての面**を同じ物差しで見る。
  await openNew(`rich-parts ${marker}`);
  const filler = Array.from({ length: 6 }, (_ignore, index) => ({ type: "paragraph", content: [{ type: "text", text: `うめ ${index}` }] }));
  const setDoc = (content) =>
    page.evaluate((body) => document.querySelector("tiptap-editor").editor.commands.setContent({ type: "doc", content: body }), content);

  await setDoc([
    ...filler,
    { type: "codeBlock", attrs: { language: "javascript" }, content: [{ type: "text", text: "const a = 1" }] },
    { type: "mathBlock", attrs: { tex: "E = mc^2" } },
    { type: "linkCard", attrs: { url: "https://example.com/parts" } },
    { type: "embed", attrs: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" } },
    { type: "paragraph" },
  ]);
  await page.waitForTimeout(1200);

  // 帯の余白（中の欄とボタンに当たらない点）を探す。
  const gapOf = (selector) =>
    page.evaluate((one) => {
      const bar = document.querySelector(one);
      if (!bar || bar.hidden) return null;
      const box = bar.getBoundingClientRect();
      if (box.height === 0) return null;
      for (let x = box.left + 3; x < box.right - 3; x += 2) {
        const y = box.top + box.height / 2;
        if (document.elementFromPoint(x, y) === bar) return { x, y };
      }
      return null;
    }, selector);
  const pickNode = (type) =>
    page.evaluate((name) => {
      const editor = document.querySelector("tiptap-editor").editor;
      let at = -1;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name === name && at < 0) at = pos;
      });
      if (at >= 0) editor.commands.setNodeSelection(at);
    }, type);

  // どの帯の余白を押しても、キャレットが出ず、打っても何も入らない。
  for (const bar of [
    { at: ".tt-code-bar", name: "コード", node: null },
    { at: ".tt-mathblock .tt-block-bar", name: "数式", node: "mathBlock" },
    { at: ".tt-link-card .tt-block-bar", name: "リンクカード", node: "linkCard" },
  ]) {
    if (bar.node) await pickNode(bar.node);
    await page.waitForTimeout(400);
    const gap = await gapOf(bar.at);
    if (!gap) {
      fail(`${bar.name} の帯の余白がある`, bar.at);
      continue;
    }
    await page.mouse.click(gap.x, gap.y);
    await page.waitForTimeout(200);
    const caret = await page.evaluate((one) => {
      const bar = document.querySelector(one);
      const picked = window.getSelection();
      return !!picked && picked.rangeCount > 0 && !!picked.anchorNode && bar.contains(picked.anchorNode);
    }, bar.at);
    check(!caret, `${bar.name} の帯の余白を押してもキャレットが出ない`, "出ました");
    await page.keyboard.type("zzzz");
    await page.waitForTimeout(300);
    const inBar = (await page.textContent(bar.at)) ?? "";
    check(!inBar.includes("zzzz"), `${bar.name} の帯に文字が入らない`, inBar.slice(0, 40));
    check(!(await docOf()).includes("zzzz"), `${bar.name} の帯の余白を押して打っても doc に入らない`, "入りました");
    await page.keyboard.press("Escape");
  }

  // 浮く面は、画面からも本文の枠からも出ない。
  const popOf = (selector) =>
    page.evaluate((one) => {
      const el = document.querySelector(one);
      if (!el || el.hidden) return null;
      const box = el.getBoundingClientRect();
      const body = document.querySelector("tiptap-editor .tt-body").getBoundingClientRect();
      return {
        height: Math.round(box.height),
        inScreen: box.top >= 0 && box.bottom <= window.innerHeight && box.left >= 0 && box.right <= window.innerWidth,
        inBody: box.bottom <= body.bottom + 1,
      };
    }, selector);

  await page.locator(".tt-code-lang").first().click();
  await page.waitForTimeout(400);
  const langPop = await popOf(".tt-code-pop");
  check(!!langPop && langPop.inScreen && langPop.inBody, "言語の候補が画面と本文の枠に収まる", JSON.stringify(langPop));

  // 本文を送っても、面は基準の欄に付いたまま（画面座標で置いていたら離れる）。
  const offsetOf = () =>
    page.evaluate(() => {
      const pop = document.querySelector(".tt-code-pop").getBoundingClientRect();
      const box = document.querySelector(".tt-code-lang").getBoundingClientRect();
      return Math.round(pop.top - box.bottom);
    });
  const offsetBefore = await offsetOf();
  await page.mouse.wheel(0, 150);
  await page.waitForTimeout(400);
  const offsetAfter = await offsetOf();
  check(Math.abs(offsetBefore - offsetAfter) <= 1, "本文を送っても言語の候補が欄に付いたまま", `${offsetBefore} → ${offsetAfter}`);
  await page.keyboard.press("Escape");
  await page.mouse.wheel(0, -300);
  await page.waitForTimeout(300);

  // 本文の一番下の段落で開く面（ブロックの一覧・埋め込みの URL）も枠から出ない。
  await page.locator("tiptap-editor .tt-body > p").last().click();
  await page.waitForTimeout(500);
  await page.locator(".tt-plus").click();
  await page.waitForTimeout(400);
  const listPop = await popOf(".tt-blocks");
  check(!!listPop && listPop.inScreen && listPop.inBody, "一番下の段落のブロックの一覧が画面と本文の枠に収まる", JSON.stringify(listPop));
  await page.locator(".tt-blocks-item", { hasText: "埋め込み" }).click();
  await page.waitForTimeout(400);
  const urlPop = await popOf(".tt-blocks");
  check(!!urlPop && urlPop.inScreen && urlPop.inBody, "一番下の段落の埋め込みの URL が画面と本文の枠に収まる", JSON.stringify(urlPop));
  await page.keyboard.press("Escape");

  // 4g. ブロックの中の全選択は、そのブロックの中だけに閉じる。
  const selectAll = process.platform === "darwin" ? "Meta+a" : "Control+a";
  await setDoc([
    { type: "paragraph", content: [{ type: "text", text: "外の段落 その 1" }] },
    { type: "codeBlock", attrs: { language: null }, content: [{ type: "text", text: "const a = 1\nconst b = 2" }] },
    { type: "paragraph", content: [{ type: "text", text: "外の段落 その 2" }] },
    { type: "mathBlock", attrs: { tex: "E = mc^2" } },
    { type: "paragraph" },
  ]);
  await page.waitForTimeout(800);

  await page.locator("tiptap-editor .tt-code pre code").click();
  await page.keyboard.press(selectAll);
  await page.waitForTimeout(300);
  const picked = await page.evaluate(() => {
    const editor = document.querySelector("tiptap-editor").editor;
    const { from, to, $from } = editor.state.selection;
    return { node: $from.parent.type.name, whole: from === $from.start() && to === $from.end(), text: editor.state.doc.textBetween(from, to, " ") };
  });
  check(picked.node === "codeBlock" && picked.whole && !picked.text.includes("外の段落"), "コードブロックの中の全選択はそのブロックだけ", JSON.stringify(picked));

  await page.locator(".tt-mathblock-out").click();
  await page.waitForTimeout(400);
  const mathBefore = await page.evaluate(() => {
    const { from, to } = document.querySelector("tiptap-editor").editor.state.selection;
    return to - from;
  });
  await page.keyboard.press(selectAll);
  await page.waitForTimeout(300);
  const inMath = await page.evaluate(() => {
    const box = document.querySelector(".tt-mathblock-src");
    const { from, to } = document.querySelector("tiptap-editor").editor.state.selection;
    return { picked: box.value.slice(box.selectionStart, box.selectionEnd), span: to - from };
  });
  check(inMath.picked === "E = mc^2" && inMath.span === mathBefore, "数式の TeX の欄の全選択は欄の中だけ", JSON.stringify(inMath));
  await page.keyboard.press("Escape");

  await page.locator(".tt-code-file").first().fill("main.ts");
  await page.locator(".tt-code-file").first().click();
  await page.keyboard.press(selectAll);
  await page.waitForTimeout(300);
  const inFile = await page.evaluate(() => {
    const box = document.querySelector(".tt-code-file");
    const { from, to } = document.querySelector("tiptap-editor").editor.state.selection;
    return { picked: box.value.slice(box.selectionStart, box.selectionEnd), span: to - from };
  });
  check(inFile.picked === "main.ts" && inFile.span <= 1, "ファイル名の欄の全選択は欄の中だけ", JSON.stringify(inFile));

  // macOS の Control+A は「行頭へ」（OS の Emacs 由来の操作を奪わない）。
  if (process.platform === "darwin") {
    await page.locator("tiptap-editor .tt-code pre code").click();
    await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      editor.commands.setTextSelection(editor.state.selection.$from.start() + 20);
    });
    await page.waitForTimeout(200);
    await page.keyboard.press("Control+a");
    await page.waitForTimeout(300);
    const ctrlA = await page.evaluate(() => {
      const editor = document.querySelector("tiptap-editor").editor;
      const { from, to, $from } = editor.state.selection;
      return { empty: from === to, atHead: from === $from.start() + 12 };
    });
    check(ctrlA.empty && ctrlA.atHead, "macOS の Control+A は全選択ではなく行頭へ", JSON.stringify(ctrlA));
  }

  // 4h. ファイル名の拡張子から言語が入る。
  const langOf = () => page.evaluate(() => document.querySelector(".tt-code-lang").value);
  const freshCode = () => setDoc([{ type: "codeBlock", attrs: { language: null }, content: [{ type: "text", text: "x" }] }, { type: "paragraph" }]);

  await freshCode();
  await page.waitForTimeout(600);
  await page.locator(".tt-code-file").first().fill("test.flix");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  check((await langOf()) === "Flix", "`test.flix` と打つと言語に Flix が入る", await langOf());

  await page.locator(".tt-code-file").first().fill("test.py");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  check((await langOf()) === "Flix", "言語を選んだ後にファイル名を変えても言語が変わらない", await langOf());

  await freshCode();
  await page.waitForTimeout(600);
  await page.locator(".tt-code-file").first().fill("test.zzzz");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(600);
  check((await langOf()) === "", "知らない拡張子では何も起きない", await langOf());

  // 4i. ツールバーが本文の枠の中で上に貼り付く（本文が長くても道具が押せる）。
  await openNew(`rich-sticky ${marker}`);
  await page.evaluate(() => {
    const body = Array.from({ length: 40 }, (_ignore, index) => ({ type: "paragraph", content: [{ type: "text", text: `長い本文の ${index} 行目です。` }] }));
    body.splice(20, 0, { type: "codeBlock", attrs: { language: null }, content: [{ type: "text", text: "const a = 1" }] });
    document.querySelector("tiptap-editor").editor.commands.setContent({ type: "doc", content: [...body, { type: "paragraph" }] });
  });
  await page.waitForTimeout(800);
  await page.mouse.wheel(0, 900);
  await page.waitForTimeout(600);
  const stuck = await page.evaluate(() => {
    const box = document.querySelector("tiptap-editor .tt-bar").getBoundingClientRect();
    const head = document.querySelector(".sticky.top-0")?.getBoundingClientRect();
    return {
      visible: box.top >= 0 && box.bottom <= window.innerHeight,
      underHead: head ? box.top < head.bottom - 1 : false,
      top: Math.round(box.top),
    };
  });
  check(stuck.visible, "本文を長くして送ってもツールバーが見える", JSON.stringify(stuck));
  check(!stuck.underHead, "ツールバーが上の帯（下書き保存 / 公開）の下に潜らない", JSON.stringify(stuck));

  // 浮く面は貼り付いた帯の上に出る（`--z-dropdown` > `--z-sticky`）。
  await page.locator("tiptap-editor .tt-code-lang").first().click();
  await page.waitForTimeout(500);
  const onTop = await page.evaluate(() => {
    const pop = document.querySelector(".tt-code-pop");
    if (!pop || pop.hidden) return null;
    const box = pop.getBoundingClientRect();
    const hit = document.elementFromPoint((box.left + box.right) / 2, box.top + 6);
    return { inPop: !!hit && !!hit.closest(".tt-code-pop") };
  });
  check(!!onTop && onTop.inPop, "言語の候補が貼り付いたツールバーの下に隠れない", JSON.stringify(onTop));
  await page.keyboard.press("Escape");

  // 「広げて書く」でも道具は残る（送るのは本文の方）。
  const bigger = page.locator('[title="広げて書く"], [aria-label="広げて書く"]').first();
  if ((await bigger.count()) > 0) {
    await bigger.click();
    await page.waitForTimeout(800);
    await page.evaluate(() => document.querySelector("tiptap-editor .tt-mount").scrollBy(0, 900));
    await page.waitForTimeout(500);
    const big = await page.evaluate(() => {
      const box = document.querySelector("tiptap-editor .tt-bar").getBoundingClientRect();
      const mount = document.querySelector("tiptap-editor .tt-mount").getBoundingClientRect();
      return { visible: box.top >= 0 && box.bottom <= window.innerHeight, aboveBody: box.bottom <= mount.top + 1 };
    });
    check(big.visible && big.aboveBody, "広げて書くでも送ったあとツールバーが見える", JSON.stringify(big));
    await page.keyboard.press("Escape");
    await page.waitForTimeout(400);
  }

  // 4j. ヘッダは「押すだけで入る物」6 個、浮く帯は「文字に掛ける物」6 個 +「…」（案 D）
  await openNew(`rich-toolbar ${marker}`);
  const shape = await page.locator(".tt-bar").first().evaluate((el) => ({
    tools: Array.from(el.querySelectorAll(".tt-tool")).map((tool) => tool.getAttribute("title")),
    block: el.querySelectorAll(".tt-block").length,
  }));
  check(shape.block === 1, "ヘッダに段落の種類のドロップダウンが 1 つ", `${shape.block} 個`);
  check(
    shape.tools.join(" / ") === "画像 / 箇条書き / 番号付き / 元に戻す（⌘Z） / やり直す（⇧⌘Z）",
    "ヘッダは 6 個（段落の種類 / 画像 / 箇条書き / 番号付き / 元に戻す / やり直す）",
    shape.tools.join(" / ")
  );
  check(
    shape.tools.every((title) => !["太字", "斜体", "打ち消し", "コード（文の中）", "数式（文の中）", "リンク", "その他の書式"].includes(title)),
    "文字に掛ける物と「…」はヘッダに出さない",
    shape.tools.join(" / ")
  );
  // 浮く帯は文字を選んだ時だけ出る
  await page.keyboard.type("たいじ");
  for (let i = 0; i < 3; i += 1) await page.keyboard.press("Shift+ArrowLeft");
  await page.waitForTimeout(400);
  const bubbleShape = await page.locator(".tt-bubble").first().evaluate((el) =>
    // 直下だけ。キャプション（出典）の 3 つは `.tt-bubble-caption` の中にいる。
    Array.from(el.querySelectorAll(":scope > .tt-bubble-tool")).filter((tool) => !tool.hidden).map((tool) => tool.getAttribute("title"))
  );
  check(
    bubbleShape.join(" / ") === "太字 / 斜体 / 打ち消し / コード（文の中） / 数式（文の中） / リンク / その他の書式",
    "浮く帯は 6 個 +「…」",
    bubbleShape.join(" / ")
  );
  await page.locator(".tt-bubble .tt-more").click();
  await page.waitForTimeout(300);
  const folded = await page.locator(".tt-more-pop").evaluate((el) => ({
    groups: Array.from(el.querySelectorAll(".tt-more-group")).map((head) => head.textContent),
    items: Array.from(el.querySelectorAll(".tt-more-item")).map((item) => item.dataset.more),
  }));
  check(folded.groups.join(" / ") === "文字", "「…」は「文字」だけ", folded.groups.join(" / "));
  check(folded.items.join(" / ") === "下線 / 蛍光ペン / 上付き / 下付き", "「…」に畳んだのは 4 つ", folded.items.join(" / "));
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  check(await page.locator(".tt-more-pop").isHidden(), "「…」は Esc で閉じる", "開いたままです");
  // ブロックを入れる物は「+」の一覧に揃っている
  await openNew(`rich-plus ${marker}`);
  await page.locator(".tt-plus").click();
  await page.waitForTimeout(300);
  const plus = await page.locator(".tt-blocks").evaluate((el) => Array.from(el.querySelectorAll(".tt-blocks-item")).map((item) => item.textContent.trim()));
  check(plus.includes("チェックリスト") && plus.includes("引用"), "チェックリストと引用は「+」の一覧にある", plus.join(" / "));
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);

  // 4k. `` `x` `` でコードにする時、前の 1 文字を巻き込まない
  //（TipTap の markInputRule は捕まえた前の 1 文字ごと消す）
  for (const [text, want] of [
    ["a`b", "a`b"],
    ["a`b`", "ab"],
    ["a *b* c", "a b c"],
    ["a **b** c", "a b c"],
  ]) {
    await openNew(`rich-tick ${text} ${marker}`);
    await page.keyboard.type(text);
    await page.waitForTimeout(400);
    const doc = JSON.parse((await docOf()) || "{}");
    const plain = (doc.content?.[0]?.content ?? []).map((node) => node.text ?? "").join("");
    check(plain === want, `「${text}」と打つと本文が「${want}」になる`, `「${plain}」になりました`);
  }
  const oneTick = await (async () => {
    await openNew(`rich-tick-one ${marker}`);
    await page.keyboard.type("`code");
    await page.waitForTimeout(400);
    return JSON.parse((await docOf()) || "{}");
  })();
  check(!types(oneTick).has("mark:code"), "バッククォート 1 つではコードにならない", JSON.stringify(oneTick).slice(0, 200));

  // 箱の右端で打った `` ` `` は箱の中に入らない（入ると 1 つでコードになったように見える）。
  // 素の文字は今までどおり箱を伸ばし、ボタンで始めたコードも続けて打てる。
  for (const [typed, want] of [
    ["`", '<p>まえ <code>code</code>`</p>'],
    ["z", "<p>まえ <code>codez</code></p>"],
  ]) {
    await openNew(`rich-tick-edge ${typed} ${marker}`);
    await page.evaluate(() => {
      document.querySelector("tiptap-editor").setAttribute(
        "doc",
        JSON.stringify({ type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "まえ " }, { type: "text", marks: [{ type: "code" }], text: "code" }] }] })
      );
    });
    await page.waitForTimeout(500);
    await page.locator(".tt-body p").first().click();
    await page.keyboard.press("End");
    await page.keyboard.type(typed);
    await page.waitForTimeout(400);
    const got = (await page.locator(".tt-body").first().innerHTML()).trim();
    check(got === want, `コードの箱の右端で「${typed}」を打つと ${want}`, got.slice(0, 200));
  }
  // 帯のボタンは文字を選んでから押す物なので、捨て字を 1 つ選んで掛け、そのまま打ち替える。
  await openNew(`rich-tick-button ${marker}`);
  await page.keyboard.type("x");
  await page.keyboard.press("Shift+ArrowLeft");
  await page.waitForTimeout(300);
  await use("コード（文の中）");
  await page.keyboard.type("abc");
  await page.waitForTimeout(400);
  const byButton = (await page.locator(".tt-body").first().innerHTML()).trim();
  check(byButton === "<p><code>abc</code></p>", "ボタンでコードにしてから打つと全部が箱に入る", byButton.slice(0, 200));

  // 4l. 入力規則の一覧（記法 → 付くマーク）。
  //
  // 記号が重なる組（`~` と `~~`、`*` と `**`、`_` と `__`、`=` と `==`、`^` の重なり）で
  // 片方が片方を食わない事を、全部の記法について 1 枚の表で見る。
  // 打つのは行の頭から（TipTap の太字・斜体・打ち消しは前が行頭か空白の時だけ効く）。
  const INPUT_RULES = [
    { text: "~~取り消し~~", want: "取り消し", marks: "strike" },
    { text: "H~2~O", want: "H2O", marks: "sub" },
    { text: "x^2^", want: "x2", marks: "sup" },
    { text: "==大事==", want: "大事", marks: "highlight" },
    { text: "a`b`", want: "ab", marks: "code" },
    { text: "**太字**", want: "太字", marks: "bold" },
    { text: "__太字__", want: "太字", marks: "bold" },
    { text: "*斜体*", want: "斜体", marks: "italic" },
    { text: "_斜体_", want: "斜体", marks: "italic" },
    { text: "~~a~~b~c~", want: "abc", marks: "strike,sub" },
    // 記号 1 つ・記号 3 つ・行の途中の `~~` は何も起きない（打った通りに残る）。
    { text: "~1つ", want: "~1つ", marks: "" },
    { text: "^1つ", want: "^1つ", marks: "" },
    { text: "=1つ", want: "=1つ", marks: "" },
    { text: "^^x^^", want: "^^x^^", marks: "" },
    { text: "~~~x~~~", want: "~~~x~~~", marks: "" },
    { text: "前~~消~~後", want: "前~~消~~後", marks: "" },
  ];
  for (const rule of INPUT_RULES) {
    await openNew(`rule ${rule.text} ${marker}`);
    await page.keyboard.type(rule.text);
    await page.waitForTimeout(400);
    const nodes = JSON.parse((await docOf()) || "{}").content?.[0]?.content ?? [];
    const plain = nodes.map((node) => node.text ?? "").join("");
    const marks = [...new Set(nodes.flatMap((node) => (node.marks ?? []).map((mark) => mark.type)))].join(",");
    check(
      plain === rule.want && marks === rule.marks,
      `「${rule.text}」→ 本文「${rule.want}」/ マーク「${rule.marks || "なし"}」`,
      `本文「${plain}」/ マーク「${marks || "なし"}」`
    );
  }

  // 4m. 掛けた装飾から抜ける道（`web/mark-escape.ts`）。
  //
  // 抜ける道は 3 つ: **→ キー / Space 2 回 / ボタンをもう一度**。
  // どれも「箱の右端に立ったカーソルから外へ出る」同じ形で、段落を変えた時は黙って落ちる。

  // 本文の 1 行を「文字[マーク]」の並びで読む。
  const lineAt = async (index) => {
    const doc = JSON.parse((await docOf()) || "{}");
    const nodes = doc.content?.[index]?.content ?? [];
    return nodes.map((node) => `${node.text ?? ""}[${(node.marks ?? []).map((mark) => mark.type).join("+") || "なし"}]`).join(" ");
  };

  // 今打った文字を左へ選ぶ（帯の道具は選んでいないと押せない）。
  const selectBack = async (count) => {
    for (let i = 0; i < count; i += 1) await page.keyboard.press("Shift+ArrowLeft");
    await page.waitForTimeout(250);
  };

  await openNew(`escape enter ${marker}`);
  await page.keyboard.type("したせん");
  await selectBack(4);
  await use("下線");
  await page.keyboard.press("Meta+ArrowRight");
  await page.keyboard.press("Enter");
  await page.keyboard.type("つぎ");
  await page.waitForTimeout(400);
  check((await lineAt(1)) === "つぎ[なし]", "Enter で新しい段落を作ると装飾が落ちる", await lineAt(1));

  await openNew(`escape list ${marker}`);
  await page.keyboard.type("- こうもく");
  await selectBack(4);
  await use("太字");
  await page.keyboard.press("Meta+ArrowRight");
  await page.keyboard.press("Enter");
  await page.keyboard.type("つぎ");
  await page.waitForTimeout(400);
  const listDoc = JSON.parse((await docOf()) || "{}");
  const second = listDoc.content?.[0]?.content?.[1]?.content?.[0]?.content?.[0] ?? {};
  check(
    (second.marks ?? []).some((mark) => mark.type === "bold"),
    "リストの項目を増やす時は装飾が残る",
    JSON.stringify(second).slice(0, 200)
  );

  // 掛けた直後は必ず「文字を選んでいる」形（帯の道具は選ばないと押せない）。
  // **そのまま → を 1 回**で抜けられる所まで見る。畳んでから押す道も同じ結果になる。
  //
  // WhyNot: 行末へ畳むのに `End` を使わない。macOS では効かず、選んだままで次の文字を
  // 打つ形になる（打った文字が選択を置き換えて、見ている物が変わる）。`Meta+ArrowRight`。
  for (const [title, word] of [["コード（文の中）", "code"], ["数式（文の中）", "x^2"]]) {
    const mark = title.startsWith("数式") ? "math" : "code";

    await openNew(`escape arrow ${mark} ${marker}`);
    await page.keyboard.type(word);
    await selectBack(word.length);
    await use(title);
    await page.keyboard.press("ArrowRight");
    await page.keyboard.type("そと");
    await page.waitForTimeout(400);
    check(
      (await lineAt(0)) === `${word}[${mark}] そと[なし]`,
      `選んでボタンを押した直後の → キーで ${title} の箱から出る`,
      await lineAt(0)
    );

    await openNew(`escape arrow caret ${mark} ${marker}`);
    await page.keyboard.type(word);
    await selectBack(word.length);
    await use(title);
    await page.keyboard.press("Meta+ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.type("そと");
    await page.waitForTimeout(400);
    check(
      (await lineAt(0)) === `${word}[${mark}] そと[なし]`,
      `行末に畳んでからの → キーで ${title} の箱から出る`,
      await lineAt(0)
    );
  }

  await openNew(`escape space ${marker}`);
  await page.keyboard.type("code");
  await selectBack(4);
  await use("コード（文の中）");
  await page.keyboard.press("Meta+ArrowRight");
  await page.keyboard.type(" ");
  await page.waitForTimeout(400);
  check((await lineAt(0)) === "code [code]", "Space 1 回では抜けない（箱の中に空白が入る）", await lineAt(0));
  await page.keyboard.type(" ");
  await page.keyboard.type("そと");
  await page.waitForTimeout(400);
  check((await lineAt(0)) === "code [code]  そと[なし]", "Space 2 回でインラインコードの箱から出る", await lineAt(0));

  await openNew(`escape button ${marker}`);
  await page.keyboard.type("code");
  await selectBack(4);
  await use("コード（文の中）");
  await page.waitForTimeout(300);
  await use("コード（文の中）");
  await page.waitForTimeout(400);
  check((await lineAt(0)) === "code[なし]", "ボタンをもう一度押すと装飾が外れる", await lineAt(0));

  // 4n. リストの項目の中で Shift+Enter した 2 行目が、1 行目の文字の左端と揃う。
  // 3 種（チェックリスト・箇条書き・番号付き）で、段落の行の箱の左端を Range から測る。
  await openNew(`list wrap ${marker}`);
  await use("チェックリスト");
  await page.keyboard.type("チェックの一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(300);
  await use("箇条書き");
  await page.keyboard.type("箇条書きの一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(300);
  await use("番号付き");
  await page.keyboard.type("番号の一行目");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("二行目");
  await page.waitForTimeout(400);
  const listLines = await page.evaluate(() =>
    [...document.querySelectorAll("tiptap-editor .tt-body li")]
      .map((li) => {
        const paragraph = li.querySelector("p");
        if (!paragraph) return null;
        const range = document.createRange();
        range.selectNodeContents(paragraph);
        return {
          kind: li.closest('ul[data-type="taskList"]') ? "チェックリスト" : li.closest("ol") ? "番号付き" : "箇条書き",
          lefts: [...range.getClientRects()].filter((box) => box.width > 0).map((box) => Math.round(box.left * 100) / 100),
        };
      })
      .filter((row) => row !== null)
  );
  check(listLines.length === 3, "3 種のリストが 1 項目ずつ出来る", JSON.stringify(listLines));
  for (const row of listLines) {
    const [first, second] = row.lefts;
    check(
      row.lefts.length === 2 && Math.abs(first - second) < 0.5,
      `${row.kind}の項目の 2 行目が 1 行目と揃う`,
      `行の左端 ${JSON.stringify(row.lefts)}`
    );
  }

  // 5. ツールバーの幅
  for (const width of [1440, 1024, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    const bar = await page.locator(".tt-bar").first().evaluate((el) => ({
      height: el.getBoundingClientRect().height,
      scroll: el.scrollWidth,
      client: el.clientWidth,
      buttons: el.querySelectorAll(".tt-tool").length,
    }));
    note(`幅 ${width} のツールバー`, `高さ ${Math.round(bar.height)} / 中身 ${bar.scroll} ≦ 枠 ${bar.client} / ボタン ${bar.buttons} 個`);
    check(bar.scroll <= bar.client + 1, `幅 ${width} でツールバーが横に溢れない`, `中身 ${bar.scroll} > 枠 ${bar.client}`);
    const outside = await page.evaluate(() => {
      const bar = document.querySelector(".tt-bar");
      const box = bar.getBoundingClientRect();
      return Array.from(bar.children)
        .filter((el) => el.getBoundingClientRect().right > box.right + 1)
        .map((el) => el.getAttribute("title") ?? el.className);
    });
    check(outside.length === 0, `幅 ${width} でボタンが枠からはみ出さない`, JSON.stringify(outside));
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // 6. CMS から読み直す
  const found = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({ query: `query entries { entries(typeId: "${blogTypeId}", first: 40) { nodes { id fields } } }` }),
  }).then((response) => response.json());
  const saved = JSON.stringify(found.data?.entries?.nodes ?? found);
  check(saved.includes('"type":"underline"'), "CMS に underline の mark が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"table"'), "CMS に table が入っている", saved.slice(0, 300));
  check(saved.includes('"type":"tableHeader"'), "CMS に tableHeader が入っている", saved.slice(0, 300));
  check(saved.includes("さんぷるの代替"), "CMS に画像の代替テキストが入っている", saved.slice(0, 300));
  check(saved.includes("src/main.ts"), "CMS に codeBlock の fileName が入っている", saved.slice(0, 300));
} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 400));
} finally {
  await browser.close();
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.log("\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`\n通りました（${steps.length} 件）。`);
