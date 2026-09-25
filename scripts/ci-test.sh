#!/bin/bash
# Runs the test suites one at a time, each with a time limit (GitHub's macOS runners are VMs with
# no GPU, where a stuck test would otherwise hang the job). Prints a pass/fail/timeout line each.
set -uo pipefail
cd "$(dirname "$0")/.."
LIMIT=${SUITE_TIMEOUT:-180}
export BETTERAIRDROP_HOME="${RUNNER_TEMP:-/tmp}/betterairdrop-home"   # never the runner's real state
swift build --build-tests 2>&1 | tail -3 || exit 1
suites=$(swift test --skip-build list 2>/dev/null | sed -E 's/^([^.]+\.[^/.]+).*/\1/' | sort -u)
fail=0
for s in $suites; do
  start=$(date +%s)
  out=$(perl -e 'alarm shift; exec @ARGV' "$LIMIT" swift test --skip-build --filter "^$s(/|\$)" 2>&1); rc=$?
  t=$(( $(date +%s) - start ))
  if [ $rc -eq 0 ]; then echo "pass    ${t}s  $s"
  elif [ $rc -eq 142 ]; then echo "TIMEOUT ${t}s  $s"; pkill -9 -f "betterairdropPackageTests" 2>/dev/null; fail=1
  else echo "FAIL    ${t}s  $s"; echo "$out" | grep -E '✘|error|failed' | head -20; fail=1; fi
done
exit $fail
