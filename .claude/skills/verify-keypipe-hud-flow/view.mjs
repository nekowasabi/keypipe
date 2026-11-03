// Chart vocabulary for HudFlow.tla, read by the /statechart skill (--view).
// Three parallel regions: what the engine is doing, the spinner, the pill.
const engine = {
  idle: "待機",
  gating: "ゲート判定中",
  matched: "規則が一致",
  running: "処理中",
  ran: "処理が終わった",
  hidden: "スピナー消去を依頼済み",
};

export const title = "keypipe: 発火からスピナーとピルが消えるまで";

export const state = (v) => ({
  処理: engine[v.pc],
  スピナー: v.spinner === 0 ? "スピナー非表示" : "スピナー表示中",
  ピル: v.pill === 0 ? "ピル非表示" : "ピル表示中",
});

const outcome = {
  ok: "成功",
  failed: "失敗",
  started: "バックグラウンド開始",
  noInput: "入力欄が消えた",
};

export const step = (action, from, to) => {
  if (action === "TriggerTyped") return "トリガーを打つ";
  if (action === "GateStops") return "ゲートで止まる（端末・パスワード欄・deny など）";
  if (action === "GatePasses") return "規則が一致する";
  if (action === "PostSpinner") return "スピナー表示を依頼";
  if (action.startsWith("RunEnds")) {
    const k = to.fire;
    return `処理が終わる（${outcome[to.result[k]] ?? to.result[k]}）`;
  }
  if (action === "PostHide") return "スピナー消去を依頼";
  if (action === "PostPill")
    return to.mainQ && Object.values(to.mainQ).some((b) => b.op === "pill")
      ? "ピル表示を依頼"
      : "ピルを出さずに戻る";
  if (action === "MainShowsSpinner") return "スピナーが出る";
  if (action === "MainHidesSpinner") return "スピナーが消える";
  if (action === "MainShowsPill") return "ピルが出る";
  if (action.startsWith("HideTimerFires"))
    return from.pill !== to.pill ? "ピルが時間切れで消える" : null;
  if (action === "Done") return null;
  return action;
};

export const group = (v) =>
  v.spinner !== 0 ? "busy" : v.pill !== 0 ? "pill" : "quiet";

export const colors = { busy: "orange", pill: "teal", quiet: "blue" };
