#!/usr/bin/env bash
# Live end-to-end naming tests with the real Claude backend (costs a few cents).
#
#   scripts/e2e.sh
#
# Runs the full pipeline on fixtures-local/ (your own AirDropped photos; gitignored, copied to a
# temp folder, never modified) plus synthetic receipt/document/screenshot images, and a simulated
# AirDrop burst through the watcher. Writes e2e-report.html (thumbnails, Vision vs Claude names,
# the context sent, tokens and cost) and e2e-results.json. Both are gitignored: they contain your photos.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d fixtures-local ]]; then
  echo "fixtures-local/ is missing: copy some AirDropped photos into it first (it's gitignored)." >&2
  exit 1
fi

swift build -q
echo "Credential check:"
.build/debug/betterairdrop auth status
if .build/debug/betterairdrop auth status | grep -q "^No credential"; then
  echo "No Anthropic credential; nothing to run. See README → Claude backend." >&2
  exit 2
fi

BETTERAIRDROP_E2E=1 swift test --filter E2E 2>&1 | grep -vE '^\s*$' | grep -E 'e2e:|✘|✔|Test run|error' || true
echo
echo "Report: $(pwd)/e2e-report.html"
[[ -f e2e-results.json ]] && python3 - <<'PY' || true
import json
d = json.load(open("e2e-results.json"))
for r in d["runs"]:
    cost = r["inputTokens"] / 1e6 * 1 + r["outputTokens"] / 1e6 * 5
    print(f'{r["name"]}: {r["photos"]} photos, {r["inputTokens"]} in / {r["outputTokens"]} out tokens, ${cost:.4f}')
print("output_config accepted:", d["structuredOutput"])
for n in d["notes"]:
    print("-", n)
bad = [r for r in d["rows"] if r["problems"]]
print(f'{len(d["rows"]) - len(bad)}/{len(d["rows"])} rows pass all checks')
PY
