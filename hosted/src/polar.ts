// Is this a live BetterAirdrop Pro key? Asks Polar's customer-portal validate endpoint, which takes
// the organization ID and no secret (https://polar.sh/docs/api-reference/customer-portal/license-keys/validate):
//   POST {api}/v1/customer-portal/license-keys/validate {key, organization_id, benefit_id?}
//   200 → the key, `status: "granted"`; 404 → unknown, revoked, disabled or expired; 422 → bad request.

export type Verdict = "valid" | "invalid" | "unavailable";

export interface PolarConfig {
  api: string;
  organizationId: string;
  /** Optional: only keys issued by this benefit (the Pro license-key benefit) count. */
  benefitId?: string;
  fetch: typeof fetch;
  now: () => Date;
}

export async function validateWithPolar(key: string, c: PolarConfig): Promise<Verdict> {
  const body: Record<string, string> = { key, organization_id: c.organizationId };
  if (c.benefitId) body.benefit_id = c.benefitId;
  let res: Response;
  try {
    res = await c.fetch(`${c.api.replace(/\/+$/, "")}/v1/customer-portal/license-keys/validate`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    return "unavailable"; // network error or timeout
  }
  if (res.status === 404) return "invalid";
  if (res.status !== 200) {
    // 5xx and 429: Polar is down or busy. 422: a request we built wrong (e.g. a bad org ID), which
    // says nothing about the key; logged so a misconfiguration shows up.
    if (res.status === 422) console.error(JSON.stringify({ event: "polar_422" }));
    return "unavailable";
  }
  let data: { status?: unknown; expires_at?: unknown };
  try {
    data = await res.json();
  } catch {
    return "unavailable";
  }
  if (data.status !== "granted") return "invalid";
  if (typeof data.expires_at === "string" && Date.parse(data.expires_at) <= c.now().getTime()) return "invalid";
  return "valid";
}
