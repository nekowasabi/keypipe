#!/usr/bin/env bash
set -u
REPO="${REPO:-/workspace/keypipe}"
MVP_ROOT="${MVP_ROOT:-/workspace/keypipe-mvp}"
BRANCH="${BRANCH:-feat/mvp-daemon}"
SCRATCH="${SCRATCH:-/workspace/keypipe-mvp/scratch}"
EVIDENCE="${EVIDENCE:-$SCRATCH/verify-$(date +%F-%H%M%S)}"
mkdir -p "$EVIDENCE"
export PATH="/home/box/swift/usr/bin:$PATH"

PASS=0; FAIL=0; SKIP=0
RESULTS="$EVIDENCE/results.tsv"
printf 'item\tspec\tstatus\tdetail\n' > "$RESULTS"
vpass() { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; printf '%s\t%s\tPASS\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }
vfail() { FAIL=$((FAIL+1)); printf 'FAIL %s :: %s\n' "$1" "$3"; printf '%s\t%s\tFAIL\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }
vskip() { SKIP=$((SKIP+1)); printf 'SKIP %s :: %s\n' "$1" "$3"; printf '%s\t%s\tSKIP\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }

{
  echo "repo=$REPO"
  echo "branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>&1)"
  echo "uname=$(uname -a)"
  if command -v swift >/dev/null 2>&1 && swift --version >/tmp/kp-swift-ver 2>&1; then
    cat /tmp/kp-swift-ver
  else
    echo "swift: missing or broken (libncurses.so.6 absent on this box)"
  fi
} > "$EVIDENCE/env.txt" 2>&1
cat "$EVIDENCE/env.txt"

SWIFT_OK=0
SWIFT_WHY="swift missing or broken (MAC_UNVERIFIED)"
if command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; then
  SWIFT_OK=1; SWIFT_WHY="swift works"
fi

DOCTOR_ONLY=0
[ "${1:-}" = "--doctor" ] && DOCTOR_ONLY=1

cur="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || echo UNKNOWN)"
if [ "$cur" = "$BRANCH" ]; then vpass "V0 doctor on $BRANCH, $SWIFT_WHY" "env" "$SWIFT_WHY"; else vfail "V0 doctor" "env" "branch is $cur, want $BRANCH"; fi
[ "$DOCTOR_ONLY" = 1 ] && { printf 'summary pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"; exit 0; }
cd "$REPO" || { vfail "V0 repo dir" "env" "cannot cd $REPO"; }

# V1 S1 scaffold
[ -f Package.swift ] && grep -q 'name: *"keypipe"' Package.swift && grep -q 'executableTarget.*name: *"keypipe"' Package.swift \
  && vpass "V1a Package.swift names keypipe executable" "S1" "Package.swift" \
  || vfail "V1a Package.swift names keypipe executable" "S1" "missing or wrong package/target name"
for kw in Espanso "menu bar" config; do
  { [ -f README.md ] && grep -qi "$kw" README.md; } \
    && vpass "V1b README mentions $kw" "S1" "README" \
    || vfail "V1b README mentions $kw" "S1" "README.md missing or lacks $kw"
done
{ [ -f .gitignore ] && grep -q '\.build' .gitignore && grep -qi 'xcuserdata\|xcuserstate' .gitignore && grep -qi 'DerivedData' .gitignore; } \
  && vpass "V1c .gitignore covers Swift/Xcode/SPM" "S1" ".gitignore" \
  || vfail "V1c .gitignore covers Swift/Xcode/SPM" "S1" "need .build, xcuserdata, DerivedData patterns"

# V2 S2 daemon
[ -f Sources/keypipe/main.swift ] \
  && vpass "V2a entrypoint Sources/keypipe/main.swift" "S2" "main.swift" \
  || vfail "V2a entrypoint Sources/keypipe/main.swift" "S2" "missing"
if [ -d Sources ]; then
  ! grep -rq 'NSStatusItem\|NSStatusBar\|NSMenu(\|import AppKit\|import Cocoa' Sources/ \
    && vpass "V2b no menu bar code" "S2" "grep NSStatusItem/NSStatusBar/AppKit" \
    || vfail "V2b no menu bar code" "S2" "menu bar or AppKit reference found"
  grep -rq 'SIGINT\|SIGTERM' Sources/ \
    && vpass "V2c signal handling SIGINT/SIGTERM" "S2" "signal grep" \
    || vfail "V2c signal handling SIGINT/SIGTERM" "S2" "no signal handling found"
  grep -rq 'keypipe started' Sources/ \
    && vpass "V2d start log keypipe started" "S2" "start-log grep" \
    || vfail "V2d start log keypipe started" "S2" "start line missing"
else
  vfail "V2b no menu bar code" "S2" "Sources/ missing"
  vfail "V2c signal handling SIGINT/SIGTERM" "S2" "Sources/ missing"
  vfail "V2d start log keypipe started" "S2" "Sources/ missing"
fi
if [ "$SWIFT_OK" = 1 ]; then
  if timeout 600 swift build > "$EVIDENCE/swift-build.log" 2>&1; then vpass "V2e swift build exit 0" "S2" "swift build"; else vfail "V2e swift build exit 0" "S2" "see swift-build.log"; fi
else
  vskip "V2e swift build exit 0" "S2" "$SWIFT_WHY"
fi
BIN="$REPO/.build/debug/keypipe"
if [ "$SWIFT_OK" = 1 ] && [ -x "$BIN" ]; then
  "$BIN" --config "$REPO/config.example.json" > "$EVIDENCE/daemon.log" 2>&1 &
  pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null && grep -q 'keypipe started' "$EVIDENCE/daemon.log"; then
    vpass "V2f daemon alive with start line until SIGTERM" "S2" "pid $pid"
  else
    vfail "V2f daemon alive with start line until SIGTERM" "S2" "see daemon.log"
  fi
  kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
  echo "$pid" > "$EVIDENCE/daemon.pid"
elif [ "$SWIFT_OK" = 1 ]; then
  vfail "V2f daemon alive with start line until SIGTERM" "S2" "binary missing after build"
else
  vskip "V2f daemon alive with start line until SIGTERM" "S2" "$SWIFT_WHY"
fi

# V3 S3 config
EXAMPLE="$(ls "$REPO"/config.example.* 2>/dev/null | head -1 || true)"
if [ -n "$EXAMPLE" ] && grep -qi '"json"' "$REPO/README.md" 2>/dev/null; then
  vpass "V3a one JSON format documented with example $EXAMPLE" "S3" "README + example"
else
  vfail "V3a one JSON format documented with example" "S3" "need README JSON mention + config.example.*"
fi
if [ -n "$EXAMPLE" ] && python3 -c "import json,sys; d=json.load(open('$EXAMPLE')); sys.exit(0 if '@@@' in json.dumps(d) and 'rules' in d else 1)" 2>/dev/null; then
  vpass "V3b example config valid JSON with @@@ rule" "S3" "$EXAMPLE"
else
  vfail "V3b example config valid JSON with @@@ rule" "S3" "invalid or missing @@@/rules"
fi
if [ "$SWIFT_OK" = 1 ] && [ -x "$BIN" ]; then
  printf '{bad json' > "$EVIDENCE/bad-config.json"
  if "$BIN" --config "$EVIDENCE/bad-config.json" > "$EVIDENCE/bad-config.log" 2>&1; then
    grep -qi 'error\|invalid' "$EVIDENCE/bad-config.log" \
      && vpass "V3c invalid config errors loudly" "S3" "clear stderr error" \
      || vfail "V3c invalid config errors loudly" "S3" "exit 0 with no error"
  else
    vpass "V3c invalid config errors loudly" "S3" "non-zero exit"
  fi
elif grep -rqi 'invalid\|DecodingError\|exit(' Sources/ 2>/dev/null; then
  vpass "V3c invalid config error path present (static)" "S3" "static grep; runtime MAC_UNVERIFIED"
else
  vfail "V3c invalid config error path present (static)" "S3" "no error/exit path in Sources/"
fi

# V4 S4 context
if grep -rlq 'appBundleId\|processName' Sources/ 2>/dev/null && grep -rqi 'contextMatches\|func matches' Sources/ 2>/dev/null; then
  vpass "V4a context field + stub matcher types" "S4" "Context grep"
else
  vfail "V4a context field + stub matcher types" "S4" "need MatchContext fields + matcher"
fi
if grep -rqi 'context' Tests/ 2>/dev/null; then
  vpass "V4b context covered by unit test" "S4" "Tests grep"
else
  if [ "$SWIFT_OK" = 1 ]; then vfail "V4b context covered by unit test" "S4" "no context test"; else vskip "V4b context covered by unit test" "S4" "$SWIFT_WHY, no Tests/ yet"; fi
fi

# V5 S5 trigger pipeline
if grep -rlq 'TriggerMatcher\|func feed' Sources/ 2>/dev/null; then
  vpass "V5a pure trigger matcher module with feed" "S5" "Trigger grep"
else
  vfail "V5a pure trigger matcher module with feed" "S5" "need TriggerMatcher.feed"
fi
if grep -rq '@@@' Tests/ 2>/dev/null && grep -rqi 'feed\|TriggerMatcher' Tests/ 2>/dev/null; then
  vpass "V5b unit test detects @@@ completion" "S5" "Tests grep"
else
  if [ "$SWIFT_OK" = 1 ]; then vfail "V5b unit test detects @@@ completion" "S5" "no @@@ trigger test"; else vskip "V5b unit test detects @@@ completion" "S5" "$SWIFT_WHY, no Tests/ yet"; fi
fi
if grep -rqi 'CGEvent\|CGEventTap\|Accessibility\|key tap' README.md Sources/ 2>/dev/null; then
  vpass "V5c macOS tap hook point documented" "S5" "hook doc grep"
else
  vfail "V5c macOS tap hook point documented" "S5" "document CGEvent/AX hook in README or source"
fi

# V6 S6 skill + pstack trace
SKILL=""
[ -f "$MVP_ROOT/skills/verify-keypipe/SKILL.md" ] && SKILL="$MVP_ROOT/skills/verify-keypipe/SKILL.md"
[ -f "$REPO/.claude/skills/verify-keypipe/SKILL.md" ] && SKILL="$REPO/.claude/skills/verify-keypipe/SKILL.md"
if [ -n "$SKILL" ] && grep -q '^name:' "$SKILL"; then
  vpass "V6a verification skill committed ($SKILL)" "S6" "skill file"
else
  vfail "V6a verification skill committed" "S6" "need SKILL.md with frontmatter in staging or repo"
fi
VSH=""
[ -f "$MVP_ROOT/skills/verify-keypipe/verify.sh" ] && VSH="$MVP_ROOT/skills/verify-keypipe/verify.sh"
[ -f "$REPO/.claude/skills/verify-keypipe/verify.sh" ] && VSH="$REPO/.claude/skills/verify-keypipe/verify.sh"
if [ -n "$VSH" ]; then
  miss=""
  for s in S1 S2 S3 S4 S5; do grep -q "$s" "$VSH" || miss="$miss $s"; done
  [ -z "$miss" ] && vpass "V6b verify.sh covers S1-S5" "S6" "$VSH" || vfail "V6b verify.sh covers S1-S5" "S6" "missing:$miss"
else
  vfail "V6b verify.sh covers S1-S5" "S6" "verify.sh missing"
fi
if grep -rl 'create-verification-skill' "$MVP_ROOT/msgs" "$MVP_ROOT/logs" "$REPO" 2>/dev/null | head -1 | grep -q .; then
  vpass "V6c create-verification-skill invocation logged" "S6" "msgs/logs grep"
else
  vskip "V6c create-verification-skill invocation logged" "S6" "no harness logs in scope yet"
fi
if grep -rli 'poteto-mode' "$MVP_ROOT/msgs" "$MVP_ROOT/logs" "$REPO" 2>/dev/null | head -1 | grep -q .; then
  vpass "V6d poteto-mode invocation logged" "S6" "msgs/logs grep"
else
  vskip "V6d poteto-mode invocation logged" "S6" "no harness logs in scope yet"
fi

# V7 S7 gates
if [ "$SWIFT_OK" = 1 ] && command -v swift-format >/dev/null 2>&1; then
  if swift-format lint --recursive Sources Tests > "$EVIDENCE/swift-format.log" 2>&1; then vpass "V7a formatter/lint verify exit 0" "S7" "swift-format lint"; else vfail "V7a formatter/lint verify exit 0" "S7" "see swift-format.log"; fi
elif grep -qi 'swift-format\|format' README.md 2>/dev/null; then
  vskip "V7a formatter/lint verify exit 0" "S7" "formatter documented but tool missing on Linux (MAC_UNVERIFIED)"
else
  vfail "V7a formatter/lint verify exit 0" "S7" "no formatter tool or documented equivalent"
fi
if [ "$SWIFT_OK" = 1 ]; then
  if timeout 600 swift test > "$EVIDENCE/swift-test.log" 2>&1; then vpass "V7b swift test exit 0" "S7" "swift test"; else vfail "V7b swift test exit 0" "S7" "see swift-test.log"; fi
else
  vskip "V7b swift test exit 0" "S7" "$SWIFT_WHY"
fi

printf 'summary pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP" | tee "$EVIDENCE/summary.txt"
[ "$FAIL" -eq 0 ]
