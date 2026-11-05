export const title = "keypipe の1回の発火: ゲートとルール選択";

export const state = (v) => {
  if (v.phase === "ready" && v.ruled === "field") return "一致: 欄を使う";
  if (v.phase === "ready") return "一致: 欄を使わない";
  if (v.phase === "done" && v.result === "nomatch") return "一致しなかった";
  if (v.phase === "done" && v.result === "unreadable") return "止めた: 事実が読めない";
  if (v.phase === "done" && v.reason === "composing") return "止めた: 変換中";
  if (v.phase === "done" && v.reason === "secure") return "止めた: パスワード";
  if (v.phase === "done" && v.reason === "terminal") return "止めた: 端末";
  if (v.phase === "done" && v.reason === "deny") return "止めた: 除外";
  if (v.phase === "done" && v.reason === "front-changed") return "止めた: 前面が変わった";
  if (v.phase === "selecting") return "ルールを選んでいる";
  if (v.phase === "matched") return "一致した: 前面を見直す";
  if (v.focus === "terminal" && v.phase !== "arrive") return "端末を通過: ホットキー";
  return "トリガーが届いた";
};

export const group = (v) => {
  if (v.phase === "ready") return "一致";
  if (v.phase === "done") return "止まった";
  return "進行中";
};

export const colors = { "進行中": "blue", "一致": "teal", "止まった": "orange" };

// NotTerminal, PassComposing, PassSecure, Rest stay inside one label, so they
// are not drawn. TerminalHotkeyPass leaves "トリガーが届いた".
export const step = (action, from, to) => {
  switch (action) {
    case "TerminalStop": return "止める [端末で文字トリガー]";
    case "TerminalHotkeyStop": return "止める [端末に欄を使わないホットキーが無い]";
    case "TerminalHotkeyPass": return "通す [端末に欄を使わないホットキーがある]";
    case "BlockComposing": return "止める [変換中]";
    case "BlockSecure": return "止める [パスワード欄]";
    case "DenyMatch": return "止める [除外リストに当たった]";
    case "DenyUnreadable": return "止める [除外の事実が読めない]";
    case "DenyClear": return "除外に当たらない";
    case "MatchField": return "欄を使うルールが一致";
    case "MatchAny": return "欄を使わないルールが一致";
    case "UnreadableStops": return "事実が読めないので次のルールへは落ちない";
    case "NoMatch": return "どのルールも条件を満たさない";
    case "FrontMoved": return "前面が変わったので消さずに止める";
    case "FrontStable":
      return to.ruled === "field" ? "前面はそのまま [欄を使う]" : "前面はそのまま [欄を使わない]";
    default: return null;
  }
};
