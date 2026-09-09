// 可変長の中身で画面が崩れないかを見る道具。読むだけ（画面のコードは触らない）。
export const base = process.env.UI_BASE ?? "http://localhost:5173";
export const adminUrl = "http://localhost:8080/p/default/admin/graphql";

export async function gql(query, variables) {
  const r = await fetch(adminUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query, variables }),
  });
  const b = await r.json();
  if (b.errors) throw new Error(JSON.stringify(b.errors).slice(0, 600));
  return b.data;
}

export const widths = [1440, 1024, 768, 390];

export async function open(page, path, wait = 1400) {
  await page.goto(base + path, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(wait);
}

// 横スクロールと、親からはみ出した要素を拾う。
export async function overflow(page) {
  return page.evaluate(() => {
    const de = document.documentElement;
    const docOver = de.scrollWidth - window.innerWidth;
    const out = [];
    const seen = new Set();
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      // 画面の右端をはみ出す（固定配置や意図的な負の位置は除く）
      const st = getComputedStyle(el);
      if (st.position === "fixed") continue;
      const over = Math.round(r.right - window.innerWidth);
      if (over > 1) {
        const key = el.tagName + "." + el.className;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
          tag: el.tagName.toLowerCase(),
          cls: String(el.className).slice(0, 90),
          text: (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 50),
          over,
          w: Math.round(r.width),
        });
      }
    }
    // 縦に伸び切って画面から出た（打ち切っていない）候補
    const tall = [];
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.height > window.innerHeight * 1.6 && r.height > 900) {
        const st = getComputedStyle(el);
        if (st.overflowY === "auto" || st.overflowY === "scroll") continue;
        tall.push({
          tag: el.tagName.toLowerCase(),
          cls: String(el.className).slice(0, 70),
          h: Math.round(r.height),
        });
      }
    }
    return { docOver, out: out.slice(0, 14), tall: tall.slice(0, 6) };
  });
}

export async function shot(page, name) {
  const p = `/tmp/ui-stress/${name}.png`;
  await page.screenshot({ path: p, fullPage: false });
  return p;
}
