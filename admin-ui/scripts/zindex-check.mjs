// 重なり順（z-index）の検査。
//
// 使い方: CMS と vite を上げてから  node scripts/zindex-check.mjs
// 見る物:
//   1. 層のトークン（--z-…）が意図した順に並んでいるか
//   2. 生の数字が散っていないか（styles.css の z-index と Tailwind の z-<数字>）
//   3. 開いた面の上に、実際にその面の中の要素が居るか（document.elementFromPoint）
//
// 3 は明暗の両方で回す。テーマで重なりが変わらない事もここで確かめる。

import { chromium } from "playwright";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const entryPath = process.env.ENTRY ?? "/p/default/c/blogs";
const problems = [];
let passed = 0;

function ok(what) {
  passed += 1;
  console.log(`  OK  ${what}`);
}

function fail(what, detail) {
  problems.push(`  NG  ${what} — ${detail}`);
}

// ---- 1. 層の順 ---------------------------------------------------------

// 下から上へ。styles.css の :root と同じ並びである事。
const layers = ["--z-dismiss", "--z-sticky", "--z-dropdown", "--z-drawer", "--z-dialog", "--z-toast", "--z-tooltip"];

// ---- 2. 生の数字 -------------------------------------------------------

function elmFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...elmFiles(path));
    else if (name.endsWith(".elm")) out.push(path);
  }
  return out;
}

// 層ごとに「Elm のクラスで使っている」「styles.css の var() で使っている」を集めて返す。
function checkSources() {
  const css = readFileSync("src/styles.css", "utf8");
  const raw = [...css.matchAll(/z-index:\s*(-?\d+)/g)].map((m) => m[0]);
  if (raw.length === 0) ok("styles.css に生の z-index が無い");
  else fail("styles.css に生の z-index が残っている", raw.join(" / "));

  const elm = new Set();
  const bad = [];
  for (const path of elmFiles("src")) {
    const text = readFileSync(path, "utf8");
    for (const m of text.matchAll(/\bz-(\d+|\[[^\]]*\])/g)) bad.push(`${path}: ${m[0]}`);
    for (const m of text.matchAll(/\bz-\((--z-[a-z-]+)\)/g)) elm.add(m[1]);
  }
  if (bad.length === 0) ok("Elm に生の z-<数字> が無い");
  else fail("Elm に生の z-<数字> が残っている", bad.join(" / "));

  const unused = layers.filter((name) => !elm.has(name) && !css.includes(`z-index: var(${name})`));
  if (unused.length === 0) ok("どの層も 1 か所以上で使われている");
  else fail("誰も使っていない層がある", unused.join(" / "));

  return elm;
}

// ---- 3. 実測 -----------------------------------------------------------

// 面の中を等間隔に突いて、返ってきた要素がその面の中かを見る。
const probe = ([selector, allowSelector]) => {
  const desc = (el) => {
    if (!el) return "(なし)";
    const cls = String(el.className || "")
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 4)
      .join(".");
    const label = (el.textContent || "").trim().slice(0, 16);
    return el.tagName.toLowerCase() + (cls ? "." + cls : "") + (label ? ` 「${label}」` : "");
  };
  const surface = document.querySelector(selector);
  if (!surface) return { missing: true };
  const allow = allowSelector ? [...document.querySelectorAll(allowSelector)] : [];
  const r = surface.getBoundingClientRect();
  const hits = [];
  const outside = [];
  for (const nx of [0.15, 0.5, 0.85]) {
    for (const ny of [0.08, 0.5, 0.92]) {
      const x = r.left + r.width * nx;
      const y = r.top + r.height * ny;
      if (x < 0 || y < 0 || x > window.innerWidth - 1 || y > window.innerHeight - 1) {
        outside.push({ x: Math.round(x), y: Math.round(y) });
        continue;
      }
      const el = document.elementFromPoint(x, y);
      const inside = !!el && (surface.contains(el) || allow.some((a) => a.contains(el)));
      hits.push({ x: Math.round(x), y: Math.round(y), inside, what: desc(el) });
    }
  }
  return { rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }, hits, outside };
};

// 開く手と、上に来ているはずの面。
const entryHref = async (page) => {
  await page.goto(base + entryPath, { waitUntil: "networkidle" });
  await page
    .waitForFunction(() => [...document.querySelectorAll("a")].some((a) => /\/c\/[^/]+\/[0-9a-f]{8,}/.test(a.getAttribute("href") || "")), null, { timeout: 15000 })
    .catch(() => {});
  await page.waitForTimeout(500);
  // **下書きの 1 件を選ぶ。** 公開中の物を開くと帯の「公開する」が押せない状態で出て、
  // 公開の面が開かない。
  const href = await page.evaluate(() => {
    const rows = [...document.querySelectorAll("a")].filter((a) => /\/c\/[^/]+\/[0-9a-f]{8,}/.test(a.getAttribute("href") || ""));
    const draft = rows.find((a) => (a.closest("tr, li, div[class*='grid']") ?? a).textContent.includes("下書き"));
    return (draft ?? rows[0])?.getAttribute("href") ?? null;
  });
  if (!href) throw new Error("コンテンツが 1 件も無い（npm run seed を先に）");
  return href;
};

async function openRef(page, index) {
  const input = page.locator("input[placeholder='検索…']").nth(index);
  await input.evaluate((el) => el.scrollIntoView({ block: "center" }));
  await page.waitForTimeout(300);
  await input.focus();
  await page.waitForTimeout(800);
}

function scenarios(entry) {
  return [
    {
      name: "編集: 1 本目の参照の候補",
      path: entry,
      open: (page) => openRef(page, 0),
      surface: "div[class*='top-9'][class*='max-h-56']",
    },
    {
      name: "編集: 2 本目の参照の候補",
      path: entry,
      open: (page) => openRef(page, 1),
      surface: "div[class*='top-9'][class*='max-h-56']",
    },
    {
      name: "編集: メディアの選択ダイアログ",
      path: entry,
      open: (page) => page.getByRole("button", { name: "メディアを選ぶ", exact: true }).first().click(),
      surface: "div[class*='inset-0'][class*='bg-black/40'] > *",
    },
    {
      name: "編集: 公開の面",
      path: entry,
      open: (page) => page.getByRole("button", { name: "公開する", exact: true }).first().click(),
      surface: "div[class*='inset-0'][class*='bg-black/40'] > *",
    },
    {
      name: "編集: API の引き出し",
      path: entry,
      open: (page) => page.getByRole("button", { name: "API", exact: true }).first().click(),
      surface: "div[class*='inset-0'][class*='justify-end'] > *",
    },
    {
      name: "編集: リンクの面",
      path: entry,
      open: async (page) => {
        await page.locator(".tt-body").click();
        await page.keyboard.press("Meta+a");
        await page.locator("button[title='リンク']").click();
      },
      surface: ".tt-link",
    },
    {
      name: "編集: 表の大きさの献立",
      path: entry,
      open: async (page) => {
        await page.locator(".tt-body").click();
        await page.locator("button[title='表']").click();
      },
      surface: ".tt-menu",
    },
    {
      name: "編集: コードブロックの言語選び",
      path: entry,
      open: async (page) => {
        await page.locator(".tt-body").click();
        await page.locator("button[title='コードブロック']").click();
        await page.waitForTimeout(500);
        await page.locator(".tt-code-lang").first().click();
      },
      surface: ".tt-code-pop",
    },
    {
      name: "編集: 広げて書く",
      path: entry,
      open: (page) => page.locator("button[title='広げて書く']").click(),
      surface: "tiptap-editor.is-big",
    },
    {
      // 広げて書く時、本文は中で送る（overflow）。**帯に付く面がそこで切られない事。**
      name: "編集: 広げて書く時の言語選び",
      path: entry,
      open: async (page) => {
        await page.locator("button[title='広げて書く']").click();
        await page.waitForTimeout(500);
        await page.locator(".tt-body").click();
        await page.keyboard.press("Meta+ArrowDown");
        for (let i = 0; i < 40; i += 1) await page.keyboard.press("Enter");
        await page.locator("button[title='コードブロック']").click();
        await page.waitForTimeout(500);
        await page.locator(".tt-code-lang").last().click();
      },
      surface: ".tt-code-pop",
    },
    {
      name: "一覧: API の引き出し",
      path: entryPath,
      open: (page) => page.getByRole("button", { name: "API", exact: true }).first().click(),
      surface: "div[class*='inset-0'][class*='justify-end'] > *",
    },
    {
      name: "ヘッダー: アカウントのメニュー",
      path: entryPath,
      open: (page) => page.getByRole("button", { name: /dev@/ }).first().click(),
      surface: "div[class*='right-2.5'][class*='top-10']",
    },
    {
      name: "ヘッダー: プロジェクトの切り替え",
      path: entryPath,
      open: (page) => page.locator("header, div").locator("button:has(> span.max-w-40)").first().click(),
      surface: "div[class*='left-10'][class*='top-10']",
    },
    {
      name: "ヘッダー: 検索",
      path: entryPath,
      open: (page) => page.getByRole("button", { name: /検索/ }).first().click(),
      surface: "div[class*='inset-0'][class*='pt-32'] > *",
    },
    {
      name: "スキーマ: 右の設定",
      path: entryPath.replace(/\/c\/([^/]+).*/, "/c/$1/schema"),
      open: (page) => page.waitForTimeout(400),
      surface: "div[class*='top-6'][class*='w-[380px]']",
    },
    {
      name: "メディア: 選んだ 1 枚のレール",
      path: "/p/default/assets",
      open: async (page) => {
        await page.locator("button:has(img)").first().click();
        await page.waitForTimeout(400);
      },
      surface: "div[class*='max-h-screen'][class*='w-72']",
    },
  ];
}

// ---- 走らせる ----------------------------------------------------------

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

try {
  const inElm = [...checkSources()];

  const entry = await entryHref(page);

  for (const theme of ["light", "dark"]) {
    await page.evaluate((t) => localStorage.setItem("theme", t), theme);

    if (theme === "light") {
      await page.reload({ waitUntil: "networkidle" });
      const values = await page.evaluate((names) => names.map((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim()), layers);
      const missing = layers.filter((_, i) => values[i] === "");
      if (missing.length > 0) {
        fail("層のトークンが引けない", missing.join(" / "));
      } else {
        const nums = values.map(Number);
        const rising = nums.every((n, i) => i === 0 || n > nums[i - 1]);
        if (rising) ok("層のトークンが下から上へ並んでいる（" + layers.map((n, i) => `${n}=${nums[i]}`).join(" < ") + "）");
        else fail("層のトークンの順が崩れている", layers.map((n, i) => `${n}=${nums[i]}`).join(" / "));
      }
    }

    if (theme === "light") {
      // 使っているクラスが CSS に出ているか。Tailwind は**書いてある物しか作らない**ので、
      // 画面に出す条件が揃わない層（知らせ）は、ここで見ないと黙って 0 になる。
      const made = await page.evaluate((names) => {
        const out = {};
        for (const name of names) {
          const el = document.createElement("div");
          el.className = `z-(${name})`;
          el.style.position = "fixed";
          document.body.appendChild(el);
          out[name] = getComputedStyle(el).zIndex;
          el.remove();
        }
        return out;
      }, inElm);
      const dead = inElm.filter((name) => !/^\d+$/.test(made[name]));
      if (dead.length === 0) ok("Elm で使っている `z-(--z-…)` のクラスが全部作られている（" + inElm.map((n) => `${n}=${made[n]}`).join(" / ") + "）");
      else fail("`z-(--z-…)` のクラスが作られていない層がある", dead.map((n) => `${n}=${made[n]}`).join(" / "));

      // 面を開いている間も、貼り付く帯のボタンは 1 回で押せる。
      await page.goto(base + entry, { waitUntil: "networkidle" });
      await page.waitForTimeout(1800);
      await openRef(page, 0);
      const bar = await page.evaluate(() => {
        const button = [...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "下書き保存");
        if (!button) return { missing: true };
        const r = button.getBoundingClientRect();
        const el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return { hit: button.contains(el) || el === button, what: el ? el.tagName.toLowerCase() + "." + String(el.className).split(/\s+/)[0] : "(なし)" };
      });
      if (bar.missing) fail("面を開いている間の「下書き保存」", "ボタンが無い");
      else if (bar.hit) ok("参照の候補を開いている間も「下書き保存」が押せる");
      else fail("参照の候補を開いている間の「下書き保存」", `上に ${bar.what} が居る`);
    }

    for (const scenario of scenarios(entry)) {
      const what = `${theme} / ${scenario.name}`;
      await page.goto(base + scenario.path, { waitUntil: "networkidle" });
      await page.waitForTimeout(1800);
      try {
        await scenario.open(page);
      } catch (error) {
        fail(what, "開けなかった: " + String(error).split("\n")[0].slice(0, 120));
        continue;
      }
      await page.waitForTimeout(800);
      const result = await page.evaluate(probe, [scenario.surface, scenario.allow ?? null]);
      if (result.missing) {
        fail(what, `面が出ていない（${scenario.surface}）`);
        continue;
      }
      // 画面の外に出ている面は、切られているのと同じで押せない（overflow で切られた面も
      // 見た目の箱だけが画面の外に伸びる）。
      if (result.outside.length > 0) {
        fail(what, `面が画面の外に出ている ${JSON.stringify(result.rect)} — 外の点 ${result.outside.map((p) => `(${p.x},${p.y})`).join(" ")}`);
        continue;
      }
      const covered = result.hits.filter((h) => !h.inside);
      if (covered.length === 0) {
        ok(`${what} — ${result.hits.length} 点とも面の中（${result.hits[0].what}）`);
      } else {
        fail(what, covered.map((h) => `(${h.x},${h.y}) に ${h.what}`).join(" / "));
      }
    }
  }
} catch (error) {
  fail("検査そのもの", String(error).split("\n")[0].slice(0, 200));
}

await browser.close();

if (problems.length === 0) {
  console.log(`\n通りました（${passed} 件）`);
} else {
  console.log("\n" + problems.join("\n"));
  console.log(`\n${problems.length} 件が落ちました（通ったのは ${passed} 件）`);
  process.exit(1);
}
