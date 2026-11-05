#!/usr/bin/env bash
# Fails when README or a SKILL.md names, in backticks, a symbol that is not in Swift
# Sources/Tests or C# src/tests. Why: docs kept naming removed or renamed symbols (feedAndRun
# in 722248c, select/matches in 9041e36, Sink for BuiltinSink) and only a review noticed.
# Checked: camelCase tokens (`replaceInput`) and Type.member (`Engine.fire`). Not checked: plain
# lowercase words, which are too often prose.
# Exception: end the line with <!-- docsym-ok: reason, expires YYYY-MM-DD, approved-by NAME -->.
set -u
cd "$(dirname "$0")/.." || exit 1
# Names that live outside this code: Apple AX roles, voice-switch's config key, an app name.
allow=" AXTextField AXTextArea superwhisperMode iTerm2 "
words=$(grep -rhoE '[A-Za-z_][A-Za-z0-9_]*' --include='*.swift' Sources Tests | sort -u)
# C# slice: index src/tests identifiers too when those trees exist, so the Windows skill can
# name FireTests.*, Keypipe.Core and friends without failing. Swift-only strictness is unchanged:
# a backtick Swift symbol missing from Sources/Tests still fails.
cs_dirs=()
[ -d src ] && cs_dirs+=(src)
[ -d tests ] && cs_dirs+=(tests)
if [ "${#cs_dirs[@]}" -gt 0 ]; then
  words=$(printf '%s\n%s' "$words" "$(grep -rhoE '[A-Za-z_][A-Za-z0-9_]*' --include='*.cs' "${cs_dirs[@]}" | sort -u)" | sort -u)
fi
fail=0
for doc in README.md README.ja.md .claude/skills/*/SKILL.md; do
  skip=" $(grep -n 'docsym-ok:' "$doc" | cut -d: -f1 | tr '\n' ' ') "
  while IFS=: read -r line tok; do
    case "$skip" in *" $line "*) continue ;; esac
    tok=${tok//\`/}
    tok=${tok%()}
    case "$allow" in *" $tok "*) continue ;; esac
    # A backtick name that is a file in the repo (Keypipe.sln at root) is documentation of
    # the tree, not a code symbol; accept it when the file exists.
    [ -e "$tok" ] && continue
    IFS=. read -ra parts <<< "$tok"
    if [ "${#parts[@]}" -lt 2 ]; then
      [[ $tok =~ [a-z][A-Z] ]] || continue
    else
      [[ ${parts[0]} =~ ^[A-Z][a-z] ]] || continue # file names, evidence names
      case "${parts[${#parts[@]}-1]}" in swift | json | jsonl | md | sh | zsh | log | tsv | sln | csproj) continue ;; esac
    fi
    for part in "${parts[@]}"; do
      if ! grep -qxF -- "$part" <<< "$words"; then
        echo "$doc:$line: \`$tok\` is not in Sources/ or Tests/ (renamed or removed?)"
        fail=1
        break
      fi
    done
  done < <(grep -noE '`[A-Za-z_][A-Za-z0-9_.]*(\(\))?`' "$doc")
done
exit "$fail"
