#!/bin/sh
# Gate for the C# fake-desktop fire path (slice 1 of the Windows port).
# Exit 0 only when `dotnet test` on Keypipe.Core.Tests is green.
# FAILs clearly when dotnet or Keypipe.sln is missing. Never runs TLC;
# the TLA specs under verify-keypipe-fire-path stay separate and must
# remain green if invoked, but C# green does not require TLC.
set -u
export PATH="$HOME/.dotnet:$PATH"

fail() { echo "FAIL: $1" >&2; exit "${2:-1}"; }

command -v dotnet >/dev/null 2>&1 || fail "dotnet not on PATH (tried \$HOME/.dotnet). Install the .NET 8 SDK, then re-run." 2

repo=$(cd "$(dirname "$0")/../../.." && pwd)
sln="$repo/Keypipe.sln"
[ -f "$sln" ] || fail "Keypipe.sln missing at $sln. The C# port has not landed; this gate cannot pass yet." 1

echo "== dotnet $(dotnet --version)"
echo "== dotnet test $sln $*"
dotnet test "$sln" "$@"
status=$?
if [ $status -eq 0 ]; then
  echo "PASS: Keypipe.Core.Tests green."
else
  echo "FAIL: dotnet test exited $status." >&2
fi
echo "NOTE: TLA check.sh stays separate (sh .claude/skills/verify-keypipe-fire-path/check.sh); this gate never runs TLC."
exit $status
