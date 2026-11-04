export const title = "トリガーの一致: 最長一致と短い方が先に終わる場合";

export const state = (v) => {
  if (v.phase === "fired" && v.fired === "aa") return "@@ が先に一致した";
  if (v.phase === "fired" && v.fired === "aaa") return "@@@ が一致した";
  if (v.phase === "fired" && v.fired === "za") return "長い方が一致した";
  if (v.phase === "fired" && v.fired === "a") return "一文字が一致した";
  if (v.buf === "") return "待っている";
  if (v.buf === "a" || v.buf === "aa") return `${v.buf.replaceAll("a", "@")} まで`;
  if (v.buf === "z") return "長い方の途中";
  return "関係ない文字";
};

export const group = (v) => (v.phase === "fired" ? "一致" : "入力中");
export const colors = { "入力中": "blue", "一致": "teal" };

export const step = (action, from, to) => {
  if (action === "Settle") return "次のキーを待つ";
  if (action === "Hotkey") return "ホットキーで文字の列を捨てる";
  if (to.phase === "fired" && to.fired === "aa") return "@@ が揃ったのでそこで発火して空にする";
  if (to.phase === "fired" && to.fired === "aaa") return "@@@ が揃った";
  if (to.phase === "fired" && to.fired === "za") return "同時に揃ったので長い方";
  if (to.phase === "fired" && to.fired === "a") return "一文字が揃った";
  if (from.buf === "" && to.buf === "a") return "@ を打つ";
  if (from.buf === "a" && to.buf === "aa") return "もう一つ @";
  if (to.buf === "z" && from.buf === "") return "長い方の最初の文字";
  return null;
};
