// 浮く面を「外のクリック」と Escape で閉じる。
//
// Elm 側の浮くメニューは `src/Ui.elm` の dismissLayer が同じ事をしている。カスタム要素の
// 中（リンクの面・コードブロックの言語）はその外に居るので、ここで揃える。

type Args = {
  // 面そのもの。この中のクリックでは閉じない（入力欄・候補・スクロールバー）。
  inside: HTMLElement[];
  onClose: () => void;
};

// 外した後に呼ぶと見張りを外す。
export function dismissOn(args: Args): () => void {
  // WhyNot: click で拾わない。開く側のボタンが click で切り替えるので、外のクリックで
  // 閉じた直後に同じクリックで開き直る。mousedown なら閉じるのが先に済む。
  const onDown = (event: MouseEvent) => {
    const target = event.target as globalThis.Node | null;
    if (target && args.inside.some((box) => box.contains(target))) return;
    args.onClose();
  };
  const onKey = (event: KeyboardEvent) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    args.onClose();
  };
  document.addEventListener("mousedown", onDown, true);
  document.addEventListener("keydown", onKey, true);
  return () => {
    document.removeEventListener("mousedown", onDown, true);
    document.removeEventListener("keydown", onKey, true);
  };
}
