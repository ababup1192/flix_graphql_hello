import { Elm } from "../Main.elm";
import { send, type Envelope } from "./api";
import "katex/dist/katex.min.css";
import "../styles.css";
import "../../web/tiptap-editor";

const root = document.getElementById("app");
const app = Elm.Main.init({ node: root, flags: null });

app.ports.apiRequest_Api_JS.subscribe(async (envelope: Envelope) => {
  const reply = await send(envelope);
  app.ports.apiResponse_Api_ELM.send(reply);
});

// 署名付き URL にファイルを PUT する。**ファイルの中身は Elm に渡さない**
// （Elm の port は File を通せない）。input 要素の中に置いたまま、ここで取り出す。
app.ports.uploadAsset_Media_JS.subscribe(async (job: { assetId: string; url: string; inputId: string }) => {
  const input = document.getElementById(job.inputId) as HTMLInputElement | null;
  const file = input?.files?.[0];
  if (!file) {
    app.ports.uploadFinished_Media_ELM.send({ assetId: job.assetId, ok: false });
    return;
  }
  try {
    const response = await fetch(job.url, {
      method: "PUT",
      headers: { "Content-Type": file.type },
      body: file,
    });
    app.ports.uploadFinished_Media_ELM.send({ assetId: job.assetId, ok: response.ok });
  } catch {
    app.ports.uploadFinished_Media_ELM.send({ assetId: job.assetId, ok: false });
  } finally {
    if (input) input.value = "";
  }
});

// テーマ。system / light / dark の 3 状態。system は属性を付けず prefers-color-scheme に任せる。
function applyTheme(theme: string) {
  if (theme === "light" || theme === "dark") {
    document.documentElement.setAttribute("data-theme", theme);
  } else {
    document.documentElement.removeAttribute("data-theme");
  }
  try {
    localStorage.setItem("theme", theme);
  } catch {
    // プライベートウィンドウなどで書けない事がある。画面は動く。
  }
}

app.ports.setTheme_Shell_JS.subscribe(applyTheme);
applyTheme(localStorage.getItem("theme") ?? "system");

// 未保存の入力があるまま閉じようとしたら止める。保存は人が押す物なので、
// これが無いと書きかけが黙って消える。Elm からは beforeunload を触れない。
let unsaved = false;
app.ports.setUnsaved_Editor_JS.subscribe((dirty: boolean) => {
  unsaved = dirty;
});
window.addEventListener("beforeunload", (event) => {
  if (!unsaved) return;
  event.preventDefault();
  event.returnValue = "";
});

// Command + S / Ctrl + S は「下書き保存」。ブラウザの「ページを保存」を止めるだけで、
// 保存そのものは Elm 側（Browser.Events.onKeyDown）が受ける。
window.addEventListener(
  "keydown",
  (event) => {
    if ((event.metaKey || event.ctrlKey) && (event.key === "s" || event.key === "S")) {
      event.preventDefault();
    }
  },
  true,
);
