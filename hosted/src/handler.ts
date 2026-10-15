// POST /v1/name: check the request, the Pro license and the caps, then name the photo.
//
// Success: 200 with the six-field answer ClaudePrompt.parse reads, plus X-Names-Remaining and
// X-Names-Reset. Errors: {"type":"error","error":{"type","message"[,"resets_at"]}}, the
// Anthropic error shape, so the app's error reader works on both.

import Anthropic from "@anthropic-ai/sdk";
import { NamingError, nameImage, type Answer } from "./name";
import type { Verdict } from "./polar";
import { RequestError, bearerKey, parseNameRequest, plausibleKey, readLimited } from "./request";
import {
  dayPeriod,
  isoSeconds,
  monthPeriod,
  nextDay,
  nextMonth,
  sha256Hex,
  type BudgetStore,
  type LicenseStore,
} from "./state";

/** A valid verdict is trusted for this long before Polar is asked again. */
export const VALID_TTL_MS = 24 * 3600_000;
/** An invalid verdict is remembered this long, so a revoked key retrying every photo doesn't hit Polar each time. */
export const INVALID_TTL_MS = 3600_000;
/** If Polar can't be reached, a key it called valid this recently is still honoured. */
export const OUTAGE_GRACE_MS = 7 * 24 * 3600_000;

export interface Deps {
  now: () => Date;
  monthlyCap: number;
  dailyCap: number;
  /** The record for a license key's SHA-256. */
  license: (keyHash: string) => LicenseStore;
  budget: () => BudgetStore;
  validate: (key: string) => Promise<Verdict>;
  name: (image: string, context: string) => Promise<Answer>;
  log?: (line: Record<string, unknown>) => void;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const res = await route(req, deps);
  // Counts only: the outcome and status, never keys, images, context or names.
  (deps.log ?? ((l) => console.log(JSON.stringify(l))))({ event: "request", status: res.status, outcome: res.headers.get("x-outcome") });
  res.headers.delete("x-outcome");
  return res;
}

async function route(req: Request, deps: Deps): Promise<Response> {
  const path = new URL(req.url).pathname;
  if (path !== "/v1/name") return error(404, "not_found", "No such endpoint.");
  if (req.method !== "POST") return error(405, "method_not_allowed", "Use POST.", { allow: "POST" });

  const key = bearerKey(req);
  if (!key) return error(401, "missing_license", "Send the BetterAirdrop Pro license key as Authorization: Bearer <key>.");

  let image: string, context: string;
  try {
    ({ image, context } = parseNameRequest(await readLimited(req)));
  } catch (e) {
    if (e instanceof RequestError) return error(e.status, e.type, e.message);
    throw e;
  }

  if (!plausibleKey(key)) return licenseInvalid();
  const license = deps.license(await sha256Hex(key));
  const auth = await authorize(license, key, deps);
  if (auth !== "ok") return auth;

  const now = deps.now();
  const month = monthPeriod(now);
  const mine = await license.consume(month, deps.monthlyCap);
  if (!mine.ok) {
    return limited("monthly_limit", nextMonth(now), now,
      `This license has used its ${deps.monthlyCap} hosted names for this month.`);
  }
  const all = await deps.budget().consume(dayPeriod(now), deps.dailyCap);
  if (!all.ok) {
    await license.release(month);
    return limited("daily_limit", nextDay(now), now, "Hosted naming has reached its daily limit.");
  }

  let answer: Answer;
  try {
    answer = await deps.name(image, context);
  } catch (e) {
    // Not delivered, so not counted against the license. The global count stays: it tracks spend.
    await license.release(month);
    if (e instanceof NamingError && e.reason === "refusal") return error(422, "refusal", e.message);
    if (e instanceof NamingError) return error(502, "bad_output", e.message);
    console.error(JSON.stringify({ event: "upstream_error", status: e instanceof Anthropic.APIError ? (e.status ?? null) : null }));
    return error(502, "upstream_error", "Claude couldn't be reached. Try again in a minute.");
  }
  return json(200, answer, {
    "x-names-remaining": String(Math.max(deps.monthlyCap - mine.used, 0)),
    "x-names-reset": isoSeconds(nextMonth(now)),
    "x-outcome": "named",
  });
}

/** "ok", or the response to send: 403 for a key Polar rejects, 503 when Polar can't say. */
async function authorize(license: LicenseStore, key: string, deps: Deps): Promise<"ok" | Response> {
  const now = deps.now().getTime();
  const cached = await license.validity();
  const age = cached ? now - cached.checkedAt : Infinity;
  if (cached?.status === "valid" && age < VALID_TTL_MS) return "ok";
  if (cached?.status === "invalid" && age < INVALID_TTL_MS) return licenseInvalid();

  const verdict = await deps.validate(key);
  if (verdict === "valid" || verdict === "invalid") {
    await license.setValidity({ status: verdict, checkedAt: now });
    return verdict === "valid" ? "ok" : licenseInvalid();
  }
  if (cached?.status === "valid" && age < OUTAGE_GRACE_MS) return "ok";
  return error(503, "license_check_unavailable", "The license can't be checked right now. Try again in a few minutes.",
    { "retry-after": "300" });
}

function licenseInvalid(): Response {
  return error(403, "license_invalid", "This BetterAirdrop Pro license key isn't valid (unknown, revoked or expired).");
}

function limited(type: string, resets: Date, now: Date, message: string): Response {
  const seconds = Math.max(Math.ceil((resets.getTime() - now.getTime()) / 1000), 1);
  return json(429, { type: "error", error: { type, message, resets_at: isoSeconds(resets) } },
    { "retry-after": String(seconds), "x-outcome": type });
}

function error(status: number, type: string, message: string, headers: Record<string, string> = {}): Response {
  return json(status, { type: "error", error: { type, message } }, { "x-outcome": type, ...headers });
}

function json(status: number, body: unknown, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}
