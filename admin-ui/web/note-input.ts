// ブロックの下に付く 1 行の入力（画像の代替テキスト・キャプション・出典、引用の出典）。
// 打ち終わり（blur）と Enter で node に書く。

// CMS が出典の URL に受ける形。`src/LinkPick.elm` の isUrlLike と違って mailto は無い
// （出典は公開側で `<cite><a>` になり、mailto を出典にする場面が無い）。
const HTTP_URL = /^https?:\/\//i;

/** 空か http(s) なら true。それ以外は CMS の validate が断るので、画面でも同じ理由で赤くする。 */
export function isHttpUrl(value: string): boolean {
  return value === "" || HTTP_URL.test(value);
}

export function noteInput(
  placeholder: string,
  className: string,
  onDone: (value: string) => void,
  onLeave: (dir: -1 | 1) => void
): HTMLInputElement {
  const input = document.createElement("input");
  input.type = "text";
  input.className = className;
  input.placeholder = placeholder;
  input.setAttribute("aria-label", placeholder);
  // WhyNot: input の度に書かない。1 文字ごとに doc が変わると undo が 1 文字ずつになり、
  // Elm への docchange も打鍵の数だけ飛ぶ。
  input.addEventListener("blur", () => onDone(input.value.trim()));
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      input.blur();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    onDone(input.value.trim());
    onLeave(event.key === "ArrowUp" ? -1 : 1);
  });
  return input;
}

/** 出典の URL の欄。http(s) でなければ赤くする。値はそのまま残す（CMS の validate と同じ理由を画面で出す）。 */
export function urlInput(
  placeholder: string,
  className: string,
  onDone: (value: string) => void,
  onLeave: (dir: -1 | 1) => void
): HTMLInputElement {
  const input = noteInput(placeholder, className, onDone, onLeave);
  input.inputMode = "url";
  const mark = () => input.classList.toggle("is-bad", !isHttpUrl(input.value.trim()));
  input.addEventListener("input", mark);
  input.addEventListener("blur", mark);
  return input;
}

/** 上下の矢印で欄を渡る。最初の欄の上と最後の欄の下でだけ外へ出る。 */
export function walkInputs(inputs: HTMLInputElement[], index: number, dir: -1 | 1, leave: (dir: -1 | 1) => void) {
  const next = index + dir;
  if (next < 0 || next >= inputs.length) {
    leave(dir);
    return;
  }
  inputs[next].focus();
}
