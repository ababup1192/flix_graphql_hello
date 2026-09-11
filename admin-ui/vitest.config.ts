import { defineConfig } from "vitest/config";
import { playwright } from "@vitest/browser-playwright";
import elmPlugin from "vite-plugin-elm";
import tailwindcss from "@tailwindcss/vite";

// 速い層の検査。**画面は描くが、サーバもログインも要らない。**
//
// WhyNot: jsdom で回さない。TipTap の node view と入力規則は本物の DOM と
// 選択の上で動いていて、jsdom では「簡易ページでは通るが実機で落ちる」が
// 起きる（実際に probe.html で起きた）。本物の chromium を裸で使う。
//
// WhyNot: 本番の画面を立てて Playwright で触らない。サーバを上げてログインして
// 記事を作るまでが検査の大半の時間を食う。ここは doc と選択だけを見る。
export default defineConfig({
  plugins: [elmPlugin({ debug: false }), tailwindcss()],
  test: {
    include: ["dev/checks/**/*.test.ts"],
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{ browser: "chromium" }],
    },
  },
});
