#!/bin/sh
# Sends the chat request on stdin (an OpenAI-style JSON body; its "model" is replaced) to the first
# target that answers and prints the reply text. A target is PROVIDER:MODEL, tried left to right:
#   jq -n --arg t "$KEYPIPE_INPUT" '{messages:[{role:"user",content:$t}]}' |
#     llm.sh 'alter:Alter#light' 'openrouter:qwen/qwen3.8-27b'
# Providers: alter (ALTER_API_KEY), openrouter (OPENROUTER_API_KEY). Each try gets LLM_TIMEOUT
# seconds (default 12); keep targets x LLM_TIMEOUT under the config's shellTimeout.
# Exit 2: bad usage, before any request. Exit 1: no target answered; stderr has one line per target.
set -u
[ $# -gt 0 ] || { echo "usage: llm.sh PROVIDER:MODEL [PROVIDER:MODEL ...] < body.json" >&2; exit 2; }
for target in "$@"; do
  case $target in
    alter:?* | openrouter:?*) ;;
    *) echo "llm: '$target' is not alter:MODEL or openrouter:MODEL" >&2; exit 2 ;;
  esac
done
body=$(cat)
printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 ||
  { echo "llm: stdin is not a JSON object" >&2; exit 2; }

for target in "$@"; do
  model=${target#*:}
  case $target in
    alter:*)
      url=https://alterhq.com/api/v1/chat/completions keyname=ALTER_API_KEY key=${ALTER_API_KEY:-}
      # Why: provider and reasoning are OpenRouter's own fields; Alter's API documents neither.
      fit='del(.provider, .reasoning)'
      ;;
    *)
      url=https://openrouter.ai/api/v1/chat/completions keyname=OPENROUTER_API_KEY
      key=${OPENROUTER_API_KEY:-}
      fit=.
      ;;
  esac
  [ -n "$key" ] || { echo "llm: $target: $keyname is not set" >&2; continue; }
  reply=$(printf '%s' "$body" | jq -c --arg m "$model" "$fit | .model = \$m" |
    curl -sS -m "${LLM_TIMEOUT:-12}" "$url" -H "Authorization: Bearer $key" \
      -H 'Content-Type: application/json' -d @- 2>&1) || { echo "llm: $target: $reply" >&2; continue; }
  text=$(printf '%s' "$reply" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  [ -z "$text" ] || { printf '%s\n' "$text"; exit 0; }
  # Why: a rate limit or a wrong model name comes back as an error body, or as a page that is not JSON.
  why=$(printf '%s' "$reply" | jq -r '.error.message? // .error // empty' 2>/dev/null)
  echo "llm: $target: ${why:-$(printf '%s' "$reply" | head -c 200)}" >&2
done
exit 1
