const frontWords = { chrome: "Chrome", safari: "Safari", slack: "Slack", plainApp: "テキストだけのアプリ" };

export const title = "テキスト選択の1回の取り込み: selection-prompt.sh";

// Only what a rule can break on stays in the label: which app until the copy, what
// the copy left, what the prompt carries. The hidden link and the rich old clipboard
// show only where they are lost, so states that differ in nothing else merge.
const app = (v) => (v.front === "safari" || v.front === "chrome" ? "ブラウザ" : frontWords[v.front]);
export const state = (v) => {
  const rich = v.oldRich && v.restored === "text" ? " [画像などが消えた]" : "";
  switch (v.phase) {
    case "start": return `ホットキーが届いた [${frontWords[v.front]}]`;
    case "cleared": return `退避して空にした [${frontWords[v.front]}]`;
    case "copied": {
      if (!v.copyOk) return "Cmd+C が失敗した";
      const got = ["テキスト"].concat(v.pbHtml ? ["HTML"] : [], v.pbSource ? ["source-url"] : []);
      return `コピーされた: ${got.join("+")} [${app(v)}]`;
    }
    case "read":
    case "restored":
    case "done": {
      if (!v.copyOk) return (v.phase === "done" ? "失敗を報告した" : "元のクリップボードを戻した（Cmd+C 失敗）") + rich;
      const out = [];
      if (v.hasLink && v.pbHtml && !v.hrefKept) out.push("リンク先を落とした");
      else if (v.hrefKept) out.push("リンク先あり");
      out.push({ none: "ページ URL なし", source: "ページ URL（source-url）", tab: "ページ URL（タブ）" }[v.pageUrl]);
      const head = { read: "読み取った", restored: "戻した", done: "プロンプトを出した" }[v.phase];
      return `${head}: ${out.join("・")}${v.phase === "read" ? "" : rich}`;
    }
  }
  return v.phase;
};

export const group = (v) => v.phase === "done" ? (v.result === "sent" ? "送った" : "止まった") : "進行中";
export const colors = { "進行中": "blue", "送った": "teal", "止まった": "orange" };

export const step = (action, from, to) => {
  switch (action) {
    case "LockSaveClear": return "ロックを取り、退避して空にする";
    case "CopyLands": return "Cmd+C";
    case "CopyFails": return "Cmd+C [失敗]";
    case "ReadCopy": {
      if (to.tabUrl === "unreadable") return "コピーを読む [タブ URL が読めない]";
      if (to.pageUrl === "tab") return "コピーを読む [タブ URL を読む]";
      return "コピーを読む";
    }
    case "Restore": return "元のクリップボードを戻す";
    case "Emit": return from.copyOk ? "プロンプトを出す" : "exit 1";
    case "Done": return null;
  }
  return action;
};
