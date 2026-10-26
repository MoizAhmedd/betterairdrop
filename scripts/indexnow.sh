#!/usr/bin/env bash
# Tell IndexNow search engines (Bing, DuckDuckGo via Bing, Yandex, Seznam, Naver) about every URL in
# the live sitemap. Run after a site change has deployed. The key is public by design: IndexNow
# checks that https://betterairdrop.com/<key>.txt serves it, which proves we own the host.
set -euo pipefail

HOST=betterairdrop.com
KEY=b0c0e34613db93c846a3d0a2bfed7c12

served=$(curl -fsS "https://$HOST/$KEY.txt")
[ "$served" = "$KEY" ] || { echo "key file not live yet at https://$HOST/$KEY.txt" >&2; exit 1; }

urls=$(curl -fsS "https://$HOST/sitemap.xml" | grep -o '<loc>[^<]*</loc>' | sed -e 's/<loc>//' -e 's/<\/loc>//')
[ -n "$urls" ] || { echo "no URLs in the sitemap" >&2; exit 1; }

body=$(python3 -c '
import json, sys
host, key = sys.argv[1], sys.argv[2]
urls = sys.stdin.read().split()
print(json.dumps({"host": host, "key": key, "keyLocation": f"https://{host}/{key}.txt", "urlList": urls}))
' "$HOST" "$KEY" <<<"$urls")

status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST https://api.indexnow.org/indexnow \
  -H 'Content-Type: application/json; charset=utf-8' --data "$body")
echo "IndexNow: HTTP $status for $(wc -w <<<"$urls" | tr -d ' ') URLs (200 or 202 = accepted)"
[ "$status" = 200 ] || [ "$status" = 202 ]
