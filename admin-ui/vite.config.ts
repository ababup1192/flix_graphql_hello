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

// 開発用の画面（`/dev/editor.html`）は**手元からしか開けない**。
//
// WhyNot: 「本番のビルドに入らない」だけで済ませない。ビルドの入口は index.html
// だけなので dist には出ないが、dev サーバは同じ LAN の相手からも引ける事があり
// （--host を付けた時、コンテナ越しの時）、偽の繋ぎ込みが付いた編集画面が外から
// 開けるのは困る。繋いできた相手が loopback かどうかで断つ。
function localOnly() {
  const loopback = (address: string | undefined) =>
    address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
  return {
    name: "dev-page-local-only",
    configureServer(server: { middlewares: { use: (fn: (req: any, res: any, next: () => void) => void) => void } }) {
      server.middlewares.use((req, res, next) => {
        if (!(req.url ?? "").startsWith("/dev/") || loopback(req.socket?.remoteAddress)) return next();
        res.statusCode = 403;
        res.end("dev page is local only");
      });
    },
    // 万一 dist に混ざったら気づけるようにする（入口に入れていないので普通は起きない）。
    generateBundle(_options: unknown, bundle: Record<string, unknown>) {
      const leaked = Object.keys(bundle).filter((name) => name.startsWith("dev/"));
      if (leaked.length > 0) throw new Error(`開発用の画面がビルドに入っています: ${leaked.join(", ")}`);
    },
  };
}

// `/p/{slug}/graphiql` を `graphiql.html?project={slug}` に読み替える。
//
// WhyNot: GraphiQL を Elm のルートに足さない。React と monaco で 1 つの塊になる物を
// index.html の入口に混ぜると、管理画面を開くたびに読む量が増える。別の入口にして、
// URL の形だけを配信側で揃える（本番は deploy/Caddyfile が同じ読み替えをする）。
function graphiqlRewrite() {
  const pattern = /^\/p\/([^/?#]+)\/graphiql\/?(?:\?.*)?$/;
  return {
    name: "graphiql-rewrite",
    configureServer(server: { middlewares: { use: (fn: (req: any, _res: any, next: () => void) => void) => void } }) {
      server.middlewares.use((req, _res, next) => {
        const matched = pattern.exec(req.url ?? "");
        if (matched) req.url = `/graphiql.html?project=${matched[1]}`;
        next();
      });
    },
  };
}

// リファレンス（`/p/{slug}/docs`）は Elm と別の入口 `docs.html`。dev では URL を書き換えて渡す。
// 本番は静的配信の側で同じ rewrite をする（deploy/Caddyfile）。
//
// WhyNot: index.html の SPA fallback に乗せて Elm から開かない。リファレンスは読者が
// エンジニアで、ログイン無しのコンテンツ API だけを叩く独立したページ。Elm のバンドルを
// 読ませる理由が無い。
function docsRewrite() {
  return {
    name: "docs-page-rewrite",
    configureServer(server: { middlewares: { use: (fn: (req: any, res: any, next: () => void) => void) => void } }) {
      server.middlewares.use((req, _res, next) => {
        const m = /^\/p\/([^/?]+)\/docs\/?(\?.*)?$/.exec(req.url ?? "");
        if (m) req.url = `/docs.html?project=${m[1]}`;
        next();
      });
    },
  };
}

export default defineConfig({
  plugins: [elmPlugin({ debug: false }), tailwindcss(), localOnly(), graphiqlRewrite(), docsRewrite()],
  build: {
    rollupOptions: {
      input: { index: "index.html", graphiql: "graphiql.html", docs: "docs.html" },
    },
  },

  // WhyNot: GraphiQL を事前バンドルに任せない。中の `monaco-editor/...?worker` は
  // vite が解く印で、事前バンドル（rolldown）はそれを普通のパスとして開こうとして
  // 「No such file or directory」で止まる（実際に dev サーバが起動しなくなった）。

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
      "^/p/[^/]+/admin/audit\\.(csv|jsonl)(\\?.*)?$": proxy,
      "^/p/[^/]+/graphql$": proxy,
      "/account/graphql": proxy,
      "/health": proxy,
    },
  },
});
