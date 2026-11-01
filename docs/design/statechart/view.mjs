const frontWords = {
  editor: "編集欄", browser: "ブラウザ", terminal: "端末",
  secureField: "パスワード欄", composing: "IME 変換中",
};
const ruleWords = { url: "URL ルール", catchAll: "汎用ルール" };
const resultWords = {
  blocked: "止めた（ゲート）", unreadable: "止めた（URL が読めない）",
  replaced: "欄を書き換えた", delivered: "打ち込んだと報告", started: "裏で起動したと報告",
  failed: "失敗を報告",
};

export const title = "keypipe の1回の発火: 同じトリガーに URL ルールと汎用ルール";

// Only the facts a rule can break on stay in the label: the front kind until the
// rule is chosen, "パスワード欄" afterwards (P6), "URL が読めないまま" once the
// catch-all took over from an unreadable fact (P5), "zsh/音声" only on a typeText result (P10).
export const state = (v) => {
  const secure = (v.front === "secureField" ? " [パスワード欄]" : "")
    + (v.url === "unreadable" && v.rule === "catchAll" ? " [URL が読めないまま]" : "");
  switch (v.phase) {
    case "start": return `トリガーが届いた [${frontWords[v.front]}]`;
    case "select": return `ゲートを通った [${frontWords[v.front]}]`;
    case "selected": return `${ruleWords[v.rule]}を選んだ${secure}`;
    case "erased": return `欄を読んでトリガーを消した（${ruleWords[v.rule]}）${secure}`;
    case "done": {
      if (v.result === "started" && !v.spawnOk) return `裏で起動したと報告、実際は起動していない${secure}`;
      if (v.out === "typeText" && v.path === "line") return `${resultWords[v.result]}（zsh/音声: 打ち込む先が無い）${secure}`;
      return `${resultWords[v.result]}${secure}`;
    }
  }
  return v.phase;
};

export const group = (v) => v.phase === "done"
  ? (["failed", "blocked", "unreadable"].includes(v.result) ? "止まった" : "配送した")
  : "進行中";
export const colors = { "進行中": "blue", "配送した": "teal", "止まった": "orange" };

export const step = (action, from, to) => {
  switch (action) {
    case "GateBlocks": return "ゲートで止める";
    case "GatePasses": return "ゲートを通す";
    case "SelectUrlRule": return "URL を読む [github]";
    case "UrlDiffers": return "URL を読む [github 以外]";
    case "UrlUnreadable": return to.phase === "done" ? "URL を読む [読めない]" : "URL を読む [読めない → 次のルールへ]";
    case "SelectCatchAll": return from.front === "browser" ? "URL は読まない [zsh/音声]" : "汎用ルールが一致";
    case "EraseAndRead": return "欄を読み、トリガーを消す";
    case "RunUrlRule": return "変換して欄に書く";
    case "RunReplaceInput": return "出力 replaceInput";
    case "RunTypeText": return from.path === "line" ? "出力 typeText [zsh/音声]" : "出力 typeText [打鍵]";
    case "RunBackground": return to.spawnOk ? "出力 background [起動できた]" : "出力 background [起動に失敗]";
    case "Done": return null;
  }
  return action;
};
