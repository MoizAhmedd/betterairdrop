// The only state the Worker keeps: per license key (by SHA-256, never the key itself) Polar's last
// verdict and this month's count, and one global count for today. No images, prompts or answers.
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
