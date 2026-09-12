// ツールバーと画像の帯が共有する SVG アイコン。

// ツールバーのアイコン。24px の枠、線 1.8（Ui.Icon と同じ流儀）。
export const ICONS = {
  paragraph: '<path d="M13 4v16"/><path d="M17 4v16"/><path d="M19 4H9.5a4.5 4.5 0 0 0 0 9H13"/>',
  code: '<path d="M16 18l6-6-6-6"/><path d="M8 6l-6 6 6 6"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  bulletList: '<path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/>',
  orderedList: '<path d="M10 6h11"/><path d="M10 12h11"/><path d="M10 18h11"/><path d="M4 6h1v4"/><path d="M4 10h2"/><path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1"/>',
  taskList: '<path d="M11 6h10"/><path d="M11 12h10"/><path d="M11 18h10"/><path d="M3 6l1.5 1.5L7 5"/><path d="M3 12l1.5 1.5L7 11"/><path d="M3 18l1.5 1.5L7 17"/>',
  quote: '<path d="M9 6H5a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2H4"/><path d="M19 6h-4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2h-1"/>',
  codeBlock: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M10 10l-2 2 2 2"/><path d="M14 10l2 2-2 2"/>',
  rule: '<path d="M3 12h18"/>',
  // WhyNot: `x²` の形にしない。上付きの道具（sup）と 16px では見分けが付かない。
  // Σ は上付き・下付きのどちらとも似ず、数式の印として通っている。
  math: '<path d="M17 5H7l6 7-6 7h10"/>',
  // 畳んだ物を開く「…」。点は塗り（線だけの丸は 16px で潰れて 3 つに見えない）。
  more: '<circle cx="5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  underline: '<path d="M7 4v6a5 5 0 0 0 10 0V4"/><path d="M5 20h14"/>',
  table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M3 15h18"/><path d="M9 10v10"/>',
  size: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  alignLeft: '<path d="M4 6h16"/><path d="M4 12h10"/><path d="M4 18h13"/>',
  alignCenter: '<path d="M4 6h16"/><path d="M7 12h10"/><path d="M6 18h12"/>',
  alignRight: '<path d="M4 6h16"/><path d="M10 12h10"/><path d="M7 18h13"/>',
  // 升の結合と解除。WhyNot: 2 つを鏡合わせにしない（内向きの矢 / 外向きの矢）。16px では
  // 矢の向きだけの違いが読めず、隣り合う 2 つが同じ印に見える。結合は「真ん中の線が切れて
  // 矢が中へ入る」、解除は「点線が 1 本通る」で、形そのものを変える。
  merge: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v3"/><path d="M12 17v3"/><path d="M9 12h6"/><path d="M13 10l2 2-2 2"/>',
  split: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16" stroke-dasharray="3 2.5"/>',
  sub: '<path d="M4 5l8 10"/><path d="M12 5l-8 10"/><path d="M20 20h-4c0-2 4-2 4-4a2 2 0 0 0-4 0"/>',
  sup: '<path d="M4 9l8 10"/><path d="M12 9l-8 10"/><path d="M20 8h-4c0-2 4-2 4-4a2 2 0 0 0-4 0"/>',
  highlight: '<path d="M4 20h16"/><path d="M6 16l8-8 3 3-8 8z"/><path d="M12 6l3-3 3 3-3 3z"/>',
  trash: '<path d="M4 7h16"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M6 7l1 13h10l1-13"/><path d="M9 7V4h6v3"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.5"/><path d="m4 17 4.5-4.5 3 3L15 12l5 5"/>',
  entry: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>',
  external: '<path d="M7 17 17 7"/><path d="M9 7h8v8"/>',
  // WhyNot: 丸い矢印（rotate-ccw / rotate-cw）にしない。16px では左右の違いが読めず、
  // 2 つ並ぶと同じ印に見える。矢の頭が横を向く形にして、向きを一目で分かるようにする。
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5A5.5 5.5 0 0 1 20 14.5 5.5 5.5 0 0 1 14.5 20H11"/>',
  // 画像の帯（image-node.ts）。縮小は矢印が内向き、拡大は外向き。16px で向きが読めるよう、
  // 対角の 2 本にして矢の頭を大きめに取る。
  shrink: '<path d="M10 14H5"/><path d="M10 14v5"/><path d="M10 14l-6 6"/><path d="M14 10h5"/><path d="M14 10V5"/><path d="M14 10l6-6"/>',
  expand: '<path d="M4 20l6-6"/><path d="M4 20h5"/><path d="M4 20v-5"/><path d="M20 4l-6 6"/><path d="M20 4h-5"/><path d="M20 4v5"/>',
  // 横に並べる = 2 列のグリッド。
  columns: '<rect x="3" y="4" width="7.5" height="16" rx="1.5"/><rect x="13.5" y="4" width="7.5" height="16" rx="1.5"/>',
  // 出典 = 引用符。
  cite: '<path d="M10 7H7a3 3 0 0 0-3 3v2a3 3 0 0 0 3 3h1v1a2 2 0 0 1-2 2H5"/><path d="M20 7h-3a3 3 0 0 0-3 3v2a3 3 0 0 0 3 3h1v1a2 2 0 0 1-2 2h-1"/>',
  // キャプションの帯（太字 / 打ち消し）。本文の帯は文字の B / S だが、キャプションの帯は note と同じくアイコン。
  bold: '<path d="M7 4h7a4 4 0 0 1 0 8H7z"/><path d="M7 12h8a4 4 0 0 1 0 8H7z"/>',
  strike: '<path d="M4 12h16"/><path d="M17 6.5c-.6-1.8-2.5-2.5-5-2.5-3 0-5 1.5-5 3.5 0 1.3.8 2.2 2.4 2.7"/><path d="M7 17.5c.6 1.8 2.5 2.5 5 2.5 3 0 5-1.5 5-3.5 0-1.3-.8-2.2-2.4-2.7"/>',
  redo: '<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5 5.5 5.5 0 0 0 9.5 20H13"/>',
  // 囲みの種別（callout-node.ts）。GitHub alerts と同じ 3 つ。
  // WhyNot: 3 つとも同じ形にして色だけ変えない。16px の帯では色の差が読めず、
  // どれが押されているか分からない（色覚の差でも消える）。形で分ける。
  note: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/>',
  tip: '<path d="M9 18h6"/><path d="M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5.9 1.1 1 1.8h5c.1-.7.4-1.3 1-1.8A6 6 0 0 0 12 3z"/>',
  warning: '<path d="M12 4 2.5 20h19z"/><path d="M12 10v4"/><path d="M12 17h.01"/>',
  // 折りたたみ。開く印の三角と、その下に畳まれている行。
  details: '<path d="M4 7l3 3 3-3"/><path d="M14 10h6"/><path d="M4 16h16"/>',
};

export function svg(paths: string, size = 16): string {
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
}
