#!/bin/sh
# PR #11 CI gate: check-docs (scripts/check-doc-symbols.sh) + dotnet test.
# Exit 0 only when BOTH pass. Never runs TLC; never touches hooks/UIA/SendInput.
# Usage: sh .claude/skills/verify-keypipe-windows-core/check.sh [-- <dotnet test args>]
set -u
repo=$(cd "$(dirname "$0")/../../.." && pwd)
echo "== bash scripts/check-doc-symbols.sh"
(cd "$repo" && bash scripts/check-doc-symbols.sh)
docs=$?
if [ "$docs" -ne 0 ]; then
  echo "FAIL: check-docs exited $docs (CI 'make check' fails the same way)." >&2
  exit "$docs"
fi
echo "PASS: check-docs clean."
echo "== verify.sh (dotnet test Keypipe.Core.Tests)"
sh "$repo/.claude/skills/verify-keypipe-windows-core/verify.sh" "$@"
tests=$?
if [ "$tests" -ne 0 ]; then
  echo "FAIL: dotnet test exited $tests." >&2
  exit "$tests"
fi
echo "PASS: check-docs + dotnet test green."
