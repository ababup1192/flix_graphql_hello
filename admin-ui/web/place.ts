// 面を押した物の下に置く。

/** 下に入らなければ上へ返す。左右は画面の中に収める。
 *
 * WhyNot: 押した物の中に `position: absolute` で置かない。本文が中で送る形（広げて書く）に
 * なると、送る箱の `overflow` に切られて面の下半分が読めず、押せもしない（実際に切れた）。
 */
export function placeUnder(dom: HTMLElement, anchor: HTMLElement, width: number) {
  const at = anchor.getBoundingClientRect();
  const gap = 6;

  const below = at.bottom + gap;
  const height = dom.offsetHeight || 260;
  const top = below + height > window.innerHeight - 8 ? Math.max(8, at.top - gap - height) : below;
  const left = Math.min(Math.max(8, at.left), window.innerWidth - width - 8);

  dom.style.position = "fixed";
  dom.style.top = `${Math.round(top)}px`;
  dom.style.left = `${Math.round(left)}px`;
  dom.style.right = "auto";
}
