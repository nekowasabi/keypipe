export const title = "トリガーを消すときの読み戻し";

export const state = (v) => {
  if (v.phase === "done" && v.handed === "body") return "入力は本文";
  if (v.phase === "done") return "一部が残った";
  if (v.applied === 0) return "まだ消えていない";
  return "一部だけ消えた";
};

export const group = (v) => (v.phase === "done" ? "決まった" : "待っている");
export const colors = { "待っている": "blue", "決まった": "teal" };

export const step = (action, from, to) => {
  if (action !== "Poll") return null;
  if (to.handed === "body" && from.applied === 0 && to.applied === 0)
    return "期限まで変わらないので書き戻す";
  if (to.handed === "body") return "トリガーが消えた";
  if (from.applied === 0) return "1文字消えたがまだ待っている";
  return null;
};
