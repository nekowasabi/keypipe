export const title = "keypipe の1回の発火: 消去から変換と送り先";

const inputWord = (v) => {
  if (v.shellInput === "empty") return "入力は空";
  if (v.shellInput === "field") return "入力は欄";
  if (v.shellInput === "supplied") return "入力は呼び出し元";
  return "入力は空";
};

export const state = (v) => {
  if (v.phase === "erase") return "入力を決める";
  if (v.phase === "routed") return inputWord(v);
  if (v.phase === "transform") return "変換する";
  if (v.phase === "fallback") return "代替の変換を一度だけ";
  if (v.phase === "output") return "送り先へ渡す";
  if (v.phase === "outfb") return "代替の送り先を一度だけ";
  if (v.result === "noInput") return "欄が消えた";
  if (v.result === "started") return "裏で起動した";
  if (v.result === "replaced") return "欄を書き換えた";
  if (v.result === "failed" && v.failStage === "transform") return "変換に失敗";
  if (v.result === "failed" && v.failStage === "spawn") return "起動に失敗";
  if (v.result === "failed") return "送り先に失敗";
  if (v.result === "delivered") return "配送した";
  return "終わった";
};

export const group = (v) => {
  if (v.phase === "done" && (v.result === "replaced" || v.result === "delivered" || v.result === "started"))
    return "配送した";
  if (v.phase === "done") return "失敗";
  return "進行中";
};

export const colors = { "進行中": "blue", "配送した": "teal", "失敗": "orange" };

const heard = (to) => {
  if (to.shellInput === "supplied") return " [呼び出し元の文字]";
  if (to.shellInput === "empty") return " [入力は空]";
  if (to.shellInput === "field") return " [入力は欄]";
  return "";
};

export const step = (action, from, to) => {
  switch (action) {
    case "EraseTextField": return "トリガーを消して欄を読む" + heard(to);
    case "ReadHotkeyField": return "消さずに欄を読む" + heard(to);
    case "EraseAnyInText": return "テキスト欄なのでトリガーだけ消す" + heard(to);
    case "SkipEraseAny": return "テキスト欄ではないので消さない" + heard(to);
    case "HotkeyAny": return "消さない" + heard(to);
    case "FieldGone": return "欄が消えていた";
    case "FieldGoneAfterErase": return "消したあと欄が消えた";
    case "BeginSync": return "同期で変換する";
    case "BackgroundOk": return "裏で起動できた";
    case "BackgroundFail": return "裏の起動に失敗";
    case "SkipTransform": return "変換は無い";
    case "PrimaryOk": return "変換できた";
    case "PrimaryFailStop": return "変換に失敗 [代替は無い]";
    case "PrimaryFailToFallback": return "変換に失敗";
    case "FallbackOk": return "代替の変換ができた";
    case "FallbackFail": return "代替の変換も失敗";
    case "ReplaceOk": return "欄を書き換えた";
    case "ShellOk": return "シェルへ渡した";
    case "NotifyOk": return "通知した";
    case "NoneOk": return null;
    case "TypeOk": return "キャレットに打ち込んだ";
    case "OutputFail": return "送り先に失敗";
    case "OutFbOk": return "代替の送り先ができた";
    case "OutFbFail": return "代替の送り先も失敗";
    default: return null;
  }
};
