// POST /v1/name (a photo) and POST /v1/name-text (a PDF's text): check the request, the Pro license
// and the caps, then name it. Both routes share the license's monthly count and the global daily cap.
//
// The free trial (`Authorization: Trial <install ID>`, photos only) has caps of its own: 25 names per
// ID for good, a daily budget apart from the paid one, and a daily share of it per network. IDs are
// free to make, so the daily budget is what bounds the spend.
//
// Success: 200 with the six-field answer the app parses (ClaudePrompt.parse for photos,
// DocumentPrompt.parse for PDFs), plus X-Names-Remaining and X-Names-Reset. Errors:
// {"type":"error","error":{"type","message"[,"resets_at"]}}, the Anthropic error shape, so the
// app's error reader works on all of them.

import Anthropic from "@anthropic-ai/sdk";
import { NamingError, type Answer, type TextAnswer } from "./name";
import type { Verdict } from "./polar";
import {
  MAX_BODY_BYTES,
  MAX_TEXT_BODY_BYTES,
  RequestError,
  bearerKey,
  imageTooLarge,
  parseNameRequest,
  parseNameTextRequest,
  network,
  plausibleKey,
  plausibleTrialId,
  readLimited,
  textTooLarge,
  trialId,
} from "./request";
import {
  dayPeriod,
  isoSeconds,
  monthPeriod,
  nextDay,
  nextMonth,
  sha256Hex,
  TRIAL_PERIOD,
  type BudgetStore,
  type LicenseStore,
  type TrialBudgetStore,
  type TrialStore,
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
  /** `mayRetry` takes another unit of the global budget before a second Anthropic call. */
  name: (image: string, context: string, mayRetry: () => Promise<boolean>) => Promise<Answer>;
  /** A PDF's text (POST /v1/name-text). Same `mayRetry` budget rule. */
  nameText: (context: string, text: string, mayRetry: () => Promise<boolean>) => Promise<TextAnswer>;
  log?: (line: Record<string, unknown>) => void;
  /** Free trial: names per trial ID (for good), per day in all, and per network per day. */
  trialCap: number;
  trialDailyCap: number;
  trialNetworkDailyCap: number;
  /** The record for a trial ID's SHA-256. */
  trial: (idHash: string) => TrialStore;
  trialBudget: () => TrialBudgetStore;
  /** Secret salt for the per-network hash. Without it the trial is off (503): no IP is ever used unsalted. */
  ipSalt?: string;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const log = deps.log ?? ((l) => console.log(JSON.stringify(l)));
  let res: Response;
  try {
    res = await route(req, deps);
  } catch (e) {
    // A Durable Object or runtime failure. The error's name only: its message could carry anything.
    log({ event: "internal_error", name: e instanceof Error ? e.name : typeof e });
    res = error(500, "internal_error", "Hosted naming hit an error. Try again in a minute.");
  }
  // Counts only: the outcome and status, never keys, images, context or names.
  log({ event: "request", status: res.status, outcome: res.headers.get("x-outcome") });
  res.headers.delete("x-outcome");
  return res;
}

async function route(req: Request, deps: Deps): Promise<Response> {
  const path = new URL(req.url).pathname;
  if (path !== "/v1/name" && path !== "/v1/name-text") return error(404, "not_found", "No such endpoint.");
  if (req.method !== "POST") return error(405, "method_not_allowed", "Use POST.", { allow: "POST" });

  const trial = trialId(req);
  const key = trial === null ? bearerKey(req) : null;
  if (!key && trial === null) return error(401, "missing_license", "Send the BetterAirdrop Pro license key as Authorization: Bearer <key>.");
  if (trial !== null && path !== "/v1/name") return error(403, "trial_photos_only", "The free trial names photos only.");

  // Everything is checked before the license or the caps: a bad request costs nothing.
  let name: (mayRetry: () => Promise<boolean>) => Promise<Answer | TextAnswer>;
  try {
    if (path === "/v1/name") {
      const { image, context } = parseNameRequest(await readLimited(req, MAX_BODY_BYTES, imageTooLarge));
      name = (mayRetry) => deps.name(image, context, mayRetry);
    } else {
      const { context, text } = parseNameTextRequest(await readLimited(req, MAX_TEXT_BODY_BYTES, textTooLarge));
      name = (mayRetry) => deps.nameText(context, text, mayRetry);
    }
  } catch (e) {
    if (e instanceof RequestError) return error(e.status, e.type, e.message);
    throw e;
  }

  if (trial !== null) return nameTrial(req, trial, name, deps);
  if (!key || !plausibleKey(key)) return licenseInvalid();
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
  // The global count is Anthropic calls (spend), not names: the structured retry takes a unit too.
  const spend = async () => (await deps.budget().consume(dayPeriod(now), deps.dailyCap)).ok;
  if (!(await spend())) {
    await license.release(month);
    return limited("daily_limit", nextDay(now), now, "Hosted naming has reached its daily limit.");
  }

  let answer: Answer | TextAnswer;
  try {
    answer = await name(spend);
  } catch (e) {
    // Not delivered, so not counted against the license. The global count stays: it tracks spend.
    await license.release(month);
    return namingFailed(e);
  }
  return json(200, answer, {
    "x-names-remaining": String(Math.max(deps.monthlyCap - mine.used, 0)),
    "x-names-reset": isoSeconds(nextMonth(now)),
    "x-outcome": "named",
  });
}

/**
 * A trial photo. The trial's daily budget is checked first: once it's spent, a flood of new IDs
 * costs one Durable Object read each and no writes. Then the ID's own 25. Never the paid budget.
 */
async function nameTrial(req: Request, id: string, name: (mayRetry: () => Promise<boolean>) => Promise<Answer | TextAnswer>,
                         deps: Deps): Promise<Response> {
  if (!plausibleTrialId(id)) return error(400, "invalid_request", "The trial ID must be a UUID.");
  if (!deps.ipSalt) return error(503, "trial_unavailable", "The free trial isn't available right now.", { "retry-after": "3600" });
  const now = deps.now();
  const day = dayPeriod(now);
  // Salted and with the day, so it can't be turned back into the IP or linked across days.
  const net = (await sha256Hex(`${deps.ipSalt}\n${day}\n${network(req.headers.get("cf-connecting-ip"))}`)).slice(0, 32);
  const budget = deps.trialBudget();
  const room = await budget.consume(day, net, deps.trialNetworkDailyCap, deps.trialDailyCap);
  if (!room.ok) {
    return limited("trial_daily_limit", nextDay(now), now, "Free trial names are used up for today. Try again tomorrow.");
  }
  const record = deps.trial(await sha256Hex(`trial:${id.toLowerCase()}`));
  const mine = await record.consume(TRIAL_PERIOD, deps.trialCap);
  if (!mine.ok) {
    await budget.release(day, net);
    return error(403, "trial_used_up", `This Mac's ${deps.trialCap} free trial names are used up.`);
  }
  let answer: Answer | TextAnswer;
  try {
    answer = await name(async () => (await budget.spend(day, deps.trialDailyCap)).ok);
  } catch (e) {
    await record.release(TRIAL_PERIOD);
    return namingFailed(e);
  }
  return json(200, answer, { "x-trial-remaining": String(Math.max(deps.trialCap - mine.used, 0)), "x-outcome": "trial_named" });
}

function namingFailed(e: unknown): Response {
  if (e instanceof NamingError && e.reason === "refusal") return error(422, "refusal", e.message);
  if (e instanceof NamingError) return error(502, "bad_output", e.message);
  console.error(JSON.stringify({ event: "upstream_error", status: e instanceof Anthropic.APIError ? (e.status ?? null) : null }));
  return error(502, "upstream_error", "Claude couldn't be reached. Try again in a minute.");
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
