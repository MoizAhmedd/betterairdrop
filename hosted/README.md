# Hosted naming

Claude-quality names for BetterAirdrop Pro, with no API key. The app sends a photo to this
Cloudflare Worker. The Worker checks the Pro license with Polar and names the photo with Claude
Haiku 5.5 on BetterAirdrop's Anthropic key.

```
POST https://api.betterairdrop.com/v1/name
Authorization: Bearer <Pro license key>
{"image": "<base64 JPEG, ≤ 768 px, ≤ 400 KB>", "context": "<ClaudePrompt.context text>"}

200 {"subject": "...", "kind": "photo", "merchant": "", "total": "", "confidence": 0.92, "people_present": false}
    X-Names-Remaining: 499
    X-Names-Reset: 2026-11-01T00:00:00Z
```

PDFs (the app's "Name PDFs too") go to a second route, with text only:

```
POST https://api.betterairdrop.com/v1/name-text
Authorization: Bearer <Pro license key>
{"context": "<DocumentPrompt.context text>", "text": "<the PDF's text, ≤ 6,000 characters>"}

200 {"subject": "internet and tv bill", "kind": "invoice", "issuer": "Bell Canada", "amount": "84.12",
     "date": "2026-10-12", "confidence": 0.9}
```

Same headers, errors, license check and caps: a PDF uses one of the license's 500 names a month and
one unit (two with the structured retry) of the global daily cap, exactly like a photo. `kind` is one
of invoice, receipt, statement, contract, form, letter, ticket, manual, paper, other; `amount` is
digits for an invoice or receipt, else `""`; `date` is `YYYY-MM-DD` or `""`.

| Status | `error.type` | When |
|---|---|---|
| 400 | `invalid_request` | Not JSON, an unknown field, not a JPEG, empty text, or the context isn't the app's |
| 401 | `missing_license` | No `Authorization: Bearer` |
| 403 | `license_invalid` | Polar says the key is unknown, revoked, disabled or expired |
| 413 | `payload_too_large` | Image over 400 KB or over 768 px; text over 6,000 characters |
| 422 | `refusal` | Claude declined the image or document |
| 429 | `monthly_limit` / `daily_limit` | 500 names per license per calendar month (UTC), or the global daily cap on Anthropic calls (a re-asked answer is two). `error.resets_at` and `Retry-After` say when it resets |
| 500 | `internal_error` | Anything unexpected (a Durable Object failure). Logged by error name only |
| 502 | `upstream_error` / `bad_output` | Anthropic failed, or answered twice with something unusable |
| 503 | `license_check_unavailable` | Polar is down and the key has no valid check from the last 7 days |

Errors use Anthropic's shape: `{"type": "error", "error": {"type", "message"}}`.

## What it pins

The client sends only the image and the context. The model (`claude-haiku-5-5`), the system prompt
(`src/prompt.json`, a copy of the app's `ClaudePrompt`), `max_tokens: 256` and thinking (off) are
fixed in `src/name.ts`. Any other field is a 400. The context must be the app's line format. Only
the six naming fields come back, each trimmed. So the key is no use as a general Claude proxy.

`/v1/name-text` pins the same way: the PDF prompt is `src/prompt-text.json` (a copy of the app's
`DocumentPrompt`), the user message is built by the Worker (`textMessage`), and only `context` and
`text` are accepted. The text is free text by nature, but what comes back is six short validated
fields (a 12-word subject, a 5-word issuer, digits, a date), so it can't be used to get anything else.

`HostedPromptTests` in the Swift tests fails if `prompt.json` and `ClaudePrompt` drift apart, and
`PDFEngineTests.workerPromptMatchesTheApp` if `prompt-text.json` and `DocumentPrompt` do.

## Cost

Measured with `count_tokens` on `claude-haiku-5-5` (2026-10-15): **1,251 input tokens** for a
768×576 photo, **1,447** for 768×768, and about **52 output tokens** for the answer. At $0.10 / $0.50
per million input / output tokens
([pricing](https://platform.claude.com/docs/en/about-claude/pricing); prompts up to 100K tokens):

| | Per photo | Per 1,000 photos |
|---|---|---|
| 4:3 photo | $0.00015 | **$0.15** |
| Square (worst case at 768 px) | $0.00017 | **$0.17** |

Budget about **$0.20 per 1,000** to cover the occasional second request (an unusable first answer).

**PDFs** (estimated, not yet measured with `count_tokens`): the PDF system prompt is about 450
tokens, the context about 40, and the text at most 4,000 characters (the app's cut), roughly 1,000
to 1,300 tokens for English invoices and statements (numbers and addresses tokenize densely), with
about 60 output tokens. That's at most about 1,800 input tokens: **$0.00021 per PDF, about $0.21
per 1,000** at the cap, nearer **$0.10–0.15** for short PDFs (a one-page receipt is a few hundred
characters). No image tokens. Budget **$0.25 per 1,000** with retries. PDFs share the photo caps,
so the monthly and daily ceilings above don't change.
One license at its 500-name cap costs at most $0.10 a month. The 5,000-a-day global cap is at most
about $1 a day, or about $30 a month.

## State and privacy

- **Stored:** for each license, the SHA-256 of the key, Polar's last verdict and when it was given,
  and this month's count. One global count for today.
- **Never stored:** keys, images, context or names. Logs carry only the status and outcome of each
  request (`{"event":"request","status":200,"outcome":"named"}`), kept by Workers Logs for 3 days
  (7 on Workers Paid). Invocation logs are off in `wrangler.jsonc`, so request headers, IP addresses
  and locations aren't logged; turning them on would change what the privacy page says.
- **Polar checks:** a valid verdict is trusted for 24 h. An invalid one is remembered for 1 h. If
  Polar can't be reached, a key it called valid in the last 7 days still works; otherwise 503.

**Why Durable Objects, not KV.** Each name writes two counters, so 5,000 names a day is about
10,000 writes, plus one write per license per day for the Polar check. Workers KV allows 1,000 writes a
day on the free plan, and its eventual consistency would let a count run past a cap. SQLite-backed
Durable Objects allow 100,000 rows written and 100,000 requests a day on the free plan, and each
object runs one call at a time, so a cap holds exactly. Each name is 3 Durable Object requests
(the cached verdict, the license count, the global count) and 2 row writes.

**Free-plan headroom** at the 5,000-a-day cap: about 5,000 Worker requests of 100,000, about 15,000
Durable Object requests of 100,000, and about 10,000 rows written of 100,000. Checking a request takes
about 3–4 ms of CPU (measured locally on a 400 KB image) against the free plan's 10 ms. If
`wrangler tail` shows "exceeded CPU" errors, move to Workers Paid ($5 a month).

## Develop

```sh
cd hosted
npm ci
npm test            # tsc + vitest (mocked Polar and Anthropic, in-memory Durable Object storage)
npm run check       # wrangler deploy --dry-run: bundles the Worker, checks wrangler.jsonc
```

## Deploy

Deploying needs Moiz's Cloudflare and Anthropic accounts.

1. **Anthropic: a workspace with a spend limit.** In the Claude Console
   (platform.claude.com), go to Settings → Workspaces and create a workspace named
   `betterairdrop-hosted`. In its Limits, set a **monthly spend limit of $40**. The global cap tops
   out near $30, so the limit only trips if something is wrong. Create an API key in that workspace.
   Its requests then can't spend past the limit or touch other projects' limits.

2. **Polar organization ID.** `POLAR_ORG_ID` in `wrangler.jsonc` is already set to BetterAirdrop's
   organization, `aadcb5c9-867d-41c0-abe3-02dd71dd8991`. It must equal `Polar.organizationID` in
   `Sources/BetterAirdropKit/PolarConstants.swift`, so change both together. It's public (the app
   ships it), so it's a var, not a secret. Pro keys look like `BA_…`. Optionally set
   `POLAR_BENEFIT_ID` to the Pro license-key benefit's ID, so only Pro keys work if the organization
   sells other keyed products.

3. **Log in and set the secret.**
   ```sh
   cd hosted && npm ci
   npx wrangler login
   npx wrangler secret put ANTHROPIC_API_KEY     # paste the workspace key from step 1
   ```

4. **Domain.** `wrangler.jsonc` routes the Worker to `api.betterairdrop.com` as a Custom Domain.
   `betterairdrop.com` must be a zone in the same Cloudflare account. Wrangler then creates the DNS
   record and the certificate. If the zone isn't on Cloudflare, set `"workers_dev": true`, remove
   `routes`, and point the app at the workers.dev URL instead (step 7).

5. **Deploy.**
   ```sh
   npx wrangler deploy
   ```
   The first deploy runs the `v1` migration, which creates the two SQLite-backed Durable Object
   classes.

6. **Smoke test** with a real Pro key and any photo:
   ```sh
   sips -s format jpeg -Z 768 ~/Desktop/some-photo.heic --out /tmp/p.jpg
   jq -n --arg image "$(base64 -i /tmp/p.jpg)" \
         --arg context "$(printf "Context worked out on the user's Mac:\n- local kind guess: photo (default)")" \
         '{image: $image, context: $context}' > /tmp/body.json
   curl -s https://api.betterairdrop.com/v1/name -H "Authorization: Bearer $PRO_KEY" \
        -H 'content-type: application/json' -d @/tmp/body.json -i
   ```
   Expect `200` with a subject and `X-Names-Remaining: 499`. A made-up key gives `403`.
   `npx wrangler tail` shows one count line per request.

7. **The app** uses `https://api.betterairdrop.com` (`HostedNamer.defaultBaseURL`). To try another
   deployment, add this to `~/.config/betterairdrop/config.toml`:
   ```toml
   [hosted]
   url = "https://betterairdrop-hosted.<account>.workers.dev"
   ```

8. **Optional hardening.** Add a Cloudflare WAF rate-limiting rule (the free plan includes one) on
   `api.betterairdrop.com/v1/name*` (both routes), for example 30 requests per 10 seconds per IP → block. Random-key
   floods then can't use up the Durable Object request quota.

### Changing the limits

`MONTHLY_CAP` and `GLOBAL_DAILY_CAP` are vars in `wrangler.jsonc`. Edit them and redeploy.
