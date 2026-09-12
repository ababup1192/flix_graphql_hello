// monaco の worker を vite に見せる。
//
// WhyNot: `graphiql/setup-workers/vite` を読まない。あれは依存パッケージの中で
// `monaco-editor/...?worker` を import していて、vite 8 の事前バンドル（rolldown）が
// `?worker` を普通のパスとして開こうとして「No such file or directory」で止まる。
// 同じ物を自分のソースに置けば、`?worker` は vite が解く印として正しく扱われる。
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker.js?worker";
import JsonWorker from "monaco-editor/esm/vs/language/json/json.worker.js?worker";
import GraphQLWorker from "monaco-graphql/esm/graphql.worker.js?worker";

const environment = {
  getWorker(_workerId: string, label: string): Worker {
    if (label === "json") return new JsonWorker();
    if (label === "graphql") return new GraphQLWorker();
    return new EditorWorker();
  },
};

(globalThis as unknown as { MonacoEnvironment: typeof environment }).MonacoEnvironment = environment;
