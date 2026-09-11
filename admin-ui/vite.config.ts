import { defineConfig, type ProxyOptions } from "vite";
import elmPlugin from "vite-plugin-elm";
import tailwindcss from "@tailwindcss/vite";

// 開発の身元。CMS は CMS_AUTH=dev のとき X-Dev-User の email をそのまま信じる。
// **ヘッダを付けるのはここだけ**。Elm も封筒の TypeScript も dev のヘッダを知らない
// （本番のビルドに混ざる事故を構造で防ぐ。CI が dist を grep して見張る）。
const devUserFallback = process.env.VITE_DEV_USER ?? "dev@localhost";

function devUserOf(cookie: string | undefined): string {
  const found = (cookie ?? "").split(";").map((part) => part.trim()).find((part) => part.startsWith("dev_user="));
  const value = found ? decodeURIComponent(found.slice("dev_user=".length)) : "";
  return value.includes("@") ? value : devUserFallback;
}

const proxy: ProxyOptions = {
  target: "http://127.0.0.1:8080",
  changeOrigin: false,
  configure(proxyServer) {
    proxyServer.on("proxyReq", (proxyReq, req) => {
      proxyReq.setHeader("X-Dev-User", devUserOf(req.headers.cookie));
    });
  },
};

export default defineConfig({
  plugins: [elmPlugin({ debug: false }), tailwindcss()],
  server: {
    port: 5173,
    strictPort: true,

    // **検査の道具では画面を読み直さない。** `scripts/` は Playwright で
    // 画面を触る物で、画面のソースではない。直す度にページが読み直されると、
    // 検査の途中で状態が消える（実際に消えて、タイマーが動かないように見えた）。
    watch: { ignored: ["**/scripts/**", "**/dist/**", "**/elm-stuff/**", "**/.devbox/**"] },
    // **API のパスだけを CMS に流す。** `/p` を丸ごと流すと、画面の URL
    // （/p/{slug}/c/{apiId} など）まで CMS に行って 404 になる。
    // 本番の Caddy も同じ分け方にする（docs/design/admin-ui-spec.md 13.2）。
    proxy: {
      "^/p/[^/]+/admin/graphql$": proxy,
      "^/p/[^/]+/admin/audit\\.(csv|jsonl)$": proxy,
      "^/p/[^/]+/graphql$": proxy,
      "/account/graphql": proxy,
      "/health": proxy,
    },
  },
});
