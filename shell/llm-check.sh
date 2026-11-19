#!/bin/sh
# Checks shell/llm.sh against a fake curl: target order, fallback, missing key, usage errors.
# Run: sh shell/llm-check.sh   (exit 0 = all pass; needs jq)
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/curl" <<'EOF'
#!/bin/sh
# Answers by host: FAKE_ALTER / FAKE_OPENROUTER hold the response body; "DOWN" exits 28.
for a in "$@"; do
  case $a in
    https://alterhq.com/*) who=alter r=$FAKE_ALTER ;;
    https://openrouter.ai/*) who=openrouter r=$FAKE_OPENROUTER ;;
  esac
done
cat >"$FAKE_DIR/$who.body"
[ "$r" != DOWN ] || { echo "curl: (28) timed out" >&2; exit 28; }
printf '%s' "$r"
EOF
chmod +x "$tmp/curl"
ok() { printf '{"choices":[{"message":{"content":"%s"}}]}' "$1"; }
body='{"model":"x","provider":{"order":["cerebras"]},"reasoning":{"effort":"low"},"messages":[]}'
fail=0
# run NAME WANT_EXIT WANT_STDOUT -- TARGET...
run() {
  name=$1 want=$2 wantout=$3
  shift 4
  rm -f "$tmp"/*.body
  out=$(printf '%s' "$body" | PATH="$tmp:$PATH" FAKE_DIR="$tmp" sh "$here/llm.sh" "$@" 2>"$tmp/err")
  got=$?
  if [ "$got" = "$want" ] && [ "$out" = "$wantout" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: exit $got (want $want), stdout '$out' (want '$wantout'), stderr: $(cat "$tmp/err")"
    fail=1
  fi
}
expect() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
export ALTER_API_KEY=a OPENROUTER_API_KEY=o FAKE_ALTER FAKE_OPENROUTER

FAKE_ALTER=$(ok A) FAKE_OPENROUTER=$(ok O)
run "L1 first target answers" 0 A -- 'alter:Alter#light' openrouter:q/q
expect "L1b alter body: model set, provider and reasoning dropped" \
  '[ "$(jq -c "[.model, has(\"provider\"), has(\"reasoning\")]" "$tmp/alter.body")" = "[\"Alter#light\",false,false]" ]'
expect "L1c the second target was not called" '[ ! -e "$tmp/openrouter.body" ]'

FAKE_ALTER='{"error":{"message":"rate limited"}}'
run "L2 error body falls to the next target" 0 O -- 'alter:Alter#light' openrouter:q/q
expect "L2b the reason is on stderr" 'grep -q "alter:Alter#light: rate limited" "$tmp/err"'
expect "L2c openrouter body keeps provider" \
  '[ "$(jq -c "[.model, has(\"provider\")]" "$tmp/openrouter.body")" = "[\"q/q\",true]" ]'

FAKE_ALTER=DOWN
run "L3 curl failure falls to the next target" 0 O -- alter:m openrouter:q/q
FAKE_ALTER='<html>busy</html>'
run "L4 a non-JSON reply falls to the next target" 0 O -- alter:m openrouter:q/q
FAKE_ALTER=$(ok A)
ALTER_API_KEY=''
run "L5 a missing key skips the target" 0 O -- alter:m openrouter:q/q
expect "L5b stderr names the variable and no request went to alter" \
  'grep -q "ALTER_API_KEY is not set" "$tmp/err" && [ ! -e "$tmp/alter.body" ]'
ALTER_API_KEY=a FAKE_ALTER=DOWN FAKE_OPENROUTER='{"error":"nope"}'
run "L6 no target answers: exit 1, nothing printed" 1 '' -- alter:m openrouter:q/q
run "L7 unknown provider: exit 2 before any request" 2 '' -- openrouter:q/q grok:m
expect "L7b no request was sent" '[ ! -e "$tmp/openrouter.body" ]'
run "L8 no targets: exit 2" 2 '' --
body='not json'
run "L9 stdin not JSON: exit 2" 2 '' -- alter:m
exit $fail
