import Anthropic from "@anthropic-ai/sdk";
import { handle } from "./handler";
import { nameImage } from "./name";
import { validateWithPolar } from "./polar";
import type { GlobalBudget, LicenseState } from "./durable";

export { GlobalBudget, LicenseState } from "./durable";

export interface Env {
  /** Secret: `wrangler secret put ANTHROPIC_API_KEY`. */
  ANTHROPIC_API_KEY: string;
  POLAR_ORG_ID: string;
  POLAR_BENEFIT_ID?: string;
  POLAR_API?: string;
  MONTHLY_CAP?: string;
  GLOBAL_DAILY_CAP?: string;
  LICENSES: DurableObjectNamespace<LicenseState>;
  BUDGET: DurableObjectNamespace<GlobalBudget>;
}

const int = (v: string | undefined, fallback: number) => {
  const n = Number.parseInt(v ?? "", 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
};

export default {
  async fetch(request, env): Promise<Response> {
    // One retry for 429/5xx/connection errors, 10 s each, plus Polar's 5 s: under the app's 30 s.
    const anthropic = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 1, timeout: 10_000 });
    return handle(request, {
      now: () => new Date(),
      monthlyCap: int(env.MONTHLY_CAP, 500),
      dailyCap: int(env.GLOBAL_DAILY_CAP, 5000),
      license: (hash) => env.LICENSES.get(env.LICENSES.idFromName(hash)),
      budget: () => env.BUDGET.get(env.BUDGET.idFromName("global")),
      validate: (key) =>
        validateWithPolar(key, {
          api: env.POLAR_API || "https://api.polar.sh",
          organizationId: env.POLAR_ORG_ID,
          benefitId: env.POLAR_BENEFIT_ID || undefined,
          fetch: (input, init) => fetch(input, init),
          now: () => new Date(),
        }),
      name: (image, context) => nameImage(anthropic, image, context),
    });
  },
} satisfies ExportedHandler<Env>;
