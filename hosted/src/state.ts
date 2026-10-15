// The only state the Worker keeps: per license key (by SHA-256, never the key itself) Polar's last
// verdict and this month's count, and one global count for today. For the free trial: per trial ID
// (by SHA-256) its lifetime count, and the trial's own count for today with a per-network count
// (a salted hash of the IP and the day, never the IP), dropped when the day ends. No images,
// prompts or answers.
//
// Each lives in a SQLite-backed Durable Object (durable.ts). These classes hold the logic over a
// tiny storage interface so tests can run them against a Map.

export interface Storage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
}

export interface Validity {
  status: "valid" | "invalid";
  /** When Polar said so (ms since epoch). */
  checkedAt: number;
}

interface Usage {
  period: string;
  used: number;
}

export interface Consumed {
  ok: boolean;
  used: number;
}

/** One row per counter: a new period simply overwrites the old one. */
async function consume(s: Storage, period: string, cap: number): Promise<Consumed> {
  const u = await s.get<Usage>("usage");
  const used = u?.period === period ? u.used : 0;
  if (used >= cap) return { ok: false, used };
  await s.put<Usage>("usage", { period, used: used + 1 });
  return { ok: true, used: used + 1 };
}

async function release(s: Storage, period: string): Promise<void> {
  const u = await s.get<Usage>("usage");
  if (u?.period === period && u.used > 0) await s.put<Usage>("usage", { period, used: u.used - 1 });
}

export class LicenseRecord {
  constructor(private readonly s: Storage) {}
  validity(): Promise<Validity | undefined> {
    return this.s.get<Validity>("validity");
  }
  setValidity(v: Validity): Promise<void> {
    return this.s.put("validity", v);
  }
  /** Counts one name this calendar month (UTC), unless the license is at `cap`. */
  consume(period: string, cap: number): Promise<Consumed> {
    return consume(this.s, period, cap);
  }
  /** Gives back a name that wasn't delivered. */
  release(period: string): Promise<void> {
    return release(this.s, period);
  }
}

export class BudgetRecord {
  constructor(private readonly s: Storage) {}
  /** Counts one Anthropic call today (UTC), unless the whole service is at `cap`. */
  consume(period: string, cap: number): Promise<Consumed> {
    return consume(this.s, period, cap);
  }
}

/** A trial request was refused: the trial's daily budget is spent, or this network's share of it. */
export interface TrialConsumed {
  ok: boolean;
  refused?: "daily" | "network";
}

interface NetworkCounts {
  period: string;
  counts: Record<string, number>;
}

/**
 * The free trial's own daily budget (a second GlobalBudget instance, "trial"), apart from the paid
 * one so trial traffic can never use up paying users' capacity. `network` is a salted hash of the
 * caller's IP and the day (handler.ts): one network gets at most `networkCap` trial names a day.
 */
export class TrialBudgetRecord {
  constructor(private readonly s: Storage) {}
  /** Counts one trial name today for this network, unless the trial or the network is at its cap. */
  async consume(period: string, network: string, networkCap: number, cap: number): Promise<TrialConsumed> {
    const u = await this.s.get<Usage>("usage");
    const used = u?.period === period ? u.used : 0;
    if (used >= cap) return { ok: false, refused: "daily" };
    const n = await this.s.get<NetworkCounts>(NETWORKS_KEY);
    const counts = n?.period === period ? n.counts : {};
    const mine = counts[network] ?? 0;
    if (mine >= networkCap) return { ok: false, refused: "network" };
    counts[network] = mine + 1;
    await this.s.put<Usage>("usage", { period, used: used + 1 });
    await this.s.put<NetworkCounts>(NETWORKS_KEY, { period, counts });
    return { ok: true };
  }
  /** The structured retry's second Anthropic call: the trial's daily count only. */
  spend(period: string, cap: number): Promise<Consumed> {
    return consume(this.s, period, cap);
  }
  /** Gives back a `consume` whose trial ID turned out to be used up. */
  async release(period: string, network: string): Promise<void> {
    await release(this.s, period);
    const n = await this.s.get<NetworkCounts>(NETWORKS_KEY);
    if (n?.period === period && (n.counts[network] ?? 0) > 0) {
      n.counts[network]! -= 1;
      await this.s.put<NetworkCounts>(NETWORKS_KEY, n);
    }
  }
}

/** The storage key of the per-network counts, which the trial budget's alarm deletes after the day ends. */
export const NETWORKS_KEY = "networks";

/** The interface both the Durable Object stubs (RPC) and the in-memory test doubles provide. */
export interface LicenseStore {
  validity(): Promise<Validity | undefined>;
  setValidity(v: Validity): Promise<void>;
  consume(period: string, cap: number): Promise<Consumed>;
  release(period: string): Promise<void>;
}
export interface BudgetStore {
  consume(period: string, cap: number): Promise<Consumed>;
}
export interface TrialBudgetStore {
  consume(period: string, network: string, networkCap: number, cap: number): Promise<TrialConsumed>;
  spend(period: string, cap: number): Promise<Consumed>;
  release(period: string, network: string): Promise<void>;
}
/** A trial ID's record: the license record's count, with one period for the trial's whole life. */
export type TrialStore = Pick<LicenseStore, "consume" | "release">;
export const TRIAL_PERIOD = "trial";

// MARK: - Periods (UTC)

export const monthPeriod = (d: Date) => d.toISOString().slice(0, 7); // "2026-10"
export const dayPeriod = (d: Date) => d.toISOString().slice(0, 10); // "2026-10-15"
export const nextMonth = (d: Date) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1));
export const nextDay = (d: Date) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1));

/** "2026-11-01T00:00:00Z": ISO 8601 without milliseconds (what Foundation's ISO8601DateFormatter reads by default). */
export const isoSeconds = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
