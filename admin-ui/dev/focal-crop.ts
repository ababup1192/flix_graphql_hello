// 開発用の注目点と切り抜きの画面。**CMS のサーバもログインも要らない**（画像だけ MinIO から）。
// 出たイベントをそのまま下に写し、次の描画で属性に書き戻す（Elm と同じ往復）。
import "../src/styles.css";
import "../web/focal-crop";
import type { FocalCropDetail } from "../web/focal-crop";

const part = document.querySelector("focal-crop") as HTMLElement;
const src = document.getElementById("src") as HTMLInputElement;
const ratio = document.getElementById("ratio") as HTMLSelectElement;
const disabled = document.getElementById("disabled") as HTMLInputElement;
const theme = document.getElementById("theme") as HTMLSelectElement;
const json = document.getElementById("json") as HTMLPreElement;

part.addEventListener("focal-crop-changed", (e) => {
  const d = (e as CustomEvent<FocalCropDetail>).detail;
  json.textContent = JSON.stringify(d, null, 2);
  part.setAttribute("focal-x", String(d.focalPoint.x));
  part.setAttribute("focal-y", String(d.focalPoint.y));
  part.setAttribute("crop-left", String(d.crop.left));
  part.setAttribute("crop-top", String(d.crop.top));
  part.setAttribute("crop-width", String(d.crop.width));
  part.setAttribute("crop-height", String(d.crop.height));
});
src.addEventListener("change", () => part.setAttribute("src", src.value));
ratio.addEventListener("change", () => part.setAttribute("ratio", ratio.value));
disabled.addEventListener("change", () => part.toggleAttribute("disabled", disabled.checked));
theme.addEventListener("change", () => {
  if (theme.value === "") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme.value);
  try {
    localStorage.setItem("theme", theme.value);
  } catch {}
});
theme.value = document.documentElement.getAttribute("data-theme") ?? "";
