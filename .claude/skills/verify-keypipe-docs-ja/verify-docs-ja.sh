#!/usr/bin/env bash
# Docs-only verifier for the Japanese README translation (docs/readme-ja).
# Checks Vd1..Vd5. Exits 0 iff zero FAILs. Read-only except the evidence dir.
set -u
REPO="${REPO:-/workspace/keypipe}"
SCRATCH="${SCRATCH:-/workspace/keypipe-mvp/scratch}"
EVIDENCE="${EVIDENCE:-$SCRATCH/verify-docs-ja-$(date +%F-%H%M%S)}"
mkdir -p "$EVIDENCE"
PASS=0; FAIL=0
RESULTS="$EVIDENCE/results.tsv"
printf 'item\tspec\tstatus\tdetail\n' > "$RESULTS"
vpass() { PASS=$((PASS+1)); printf 'PASS %s :: %s\n' "$1" "$3"; printf '%s\t%s\tPASS\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }
vfail() { FAIL=$((FAIL+1)); printf 'FAIL %s :: %s\n' "$1" "$3"; printf '%s\t%s\tFAIL\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }

{
  echo "repo=$REPO"
  echo "branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>&1)"
  echo "sha=$(git -C "$REPO" rev-parse HEAD 2>&1)"
} > "$EVIDENCE/env.txt" 2>&1
cat "$EVIDENCE/env.txt"
cd "$REPO" || { vfail "Vd0 repo dir" "env" "cannot cd $REPO"; printf 'summary pass=%d fail=%d\n' "$PASS" "$FAIL" | tee "$EVIDENCE/summary.txt"; exit 1; }

# Vd1: README.ja.md exists and is non-empty
if [ -s README.ja.md ]; then
  vpass "Vd1 README.ja.md exists and non-empty" "docs-ja" "size $(wc -c < README.ja.md) bytes"
else
  if [ -e README.ja.md ]; then
    vfail "Vd1 README.ja.md exists and non-empty" "docs-ja" "file exists but is empty"
  else
    vfail "Vd1 README.ja.md exists and non-empty" "docs-ja" "README.ja.md missing"
  fi
fi

# Vd2: README.md links to README.ja.md
if [ -f README.md ] && grep -q 'README\.ja\.md' README.md; then
  vpass "Vd2 README.md links to README.ja.md" "docs-ja" "link found in README.md"
else
  vfail "Vd2 README.md links to README.ja.md" "docs-ja" "README.md missing or lacks README.ja.md link"
fi

# Vd3: README.ja.md links to README.md
if [ -f README.ja.md ] && grep -q 'README\.md' README.ja.md; then
  vpass "Vd3 README.ja.md links to README.md" "docs-ja" "link found in README.ja.md"
else
  vfail "Vd3 README.ja.md links to README.md" "docs-ja" "README.ja.md missing or lacks README.md link"
fi

# Vd4: Japanese content present
if [ -f README.ja.md ] && grep -q -e 'キーシーケンス' -e 'デーモン' -e 'バックグラウンド' README.ja.md; then
  vpass "Vd4 README.ja.md contains Japanese content" "docs-ja" "found キーシーケンス/デーモン/バックグラウンド"
else
  vfail "Vd4 README.ja.md contains Japanese content" "docs-ja" "need キーシーケンス or デーモン or バックグラウンド"
fi

# Vd5: technical terms preserved (@@@, --smoke-feed, --config)
if [ -f README.ja.md ] \
  && grep -q -F '@@@' README.ja.md \
  && grep -q -F -- '--smoke-feed' README.ja.md \
  && grep -q -F -- '--config' README.ja.md; then
  vpass "Vd5 README.ja.md preserves @@@, --smoke-feed, --config" "docs-ja" "all technical terms present"
else
  miss=""
  [ -f README.ja.md ] || miss="${miss} no-file"
  [ -f README.ja.md ] && grep -q -F '@@@' README.ja.md || miss="${miss} @@@"
  [ -f README.ja.md ] && grep -q -F -- '--smoke-feed' README.ja.md || miss="${miss} --smoke-feed"
  [ -f README.ja.md ] && grep -q -F -- '--config' README.ja.md || miss="${miss} --config"
  vfail "Vd5 README.ja.md preserves @@@, --smoke-feed, --config" "docs-ja" "missing:${miss}"
fi

printf 'summary pass=%d fail=%d\n' "$PASS" "$FAIL" | tee "$EVIDENCE/summary.txt"
[ "$FAIL" -eq 0 ]
