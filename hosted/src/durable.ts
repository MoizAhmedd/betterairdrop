// The two SQLite-backed Durable Objects. Each call is one storage read and at most one write; a
// Durable Object runs one call at a time, so a count can't be raced past its cap.

import { DurableObject } from "cloudflare:workers";
import { BudgetRecord, LicenseRecord, NETWORKS_KEY, TrialBudgetRecord, nextDay, type Consumed, type TrialConsumed, type Validity } from "./state";

/** One per license key, named by the key's SHA-256: Polar's last verdict and this month's count. */
export class LicenseState extends DurableObject {
  private readonly record = new LicenseRecord(this.ctx.storage);
  validity(): Promise<Validity | undefined> {
    return this.record.validity();
  }
  setValidity(v: Validity): Promise<void> {
    return this.record.setValidity(v);
  }
  consume(period: string, cap: number): Promise<Consumed> {
    return this.record.consume(period, cap);
  }
  release(period: string): Promise<void> {
    return this.record.release(period);
  }
}

/**
 * Two instances. "global": today's count of paid Anthropic calls, the cost circuit-breaker.
 * "trial": the free trial's own count for today, and its per-network counts (TrialBudgetRecord),
 * which an alarm deletes once the day is over.
 */
export class GlobalBudget extends DurableObject {
  private readonly record = new BudgetRecord(this.ctx.storage);
  private readonly trial = new TrialBudgetRecord(this.ctx.storage);
  consume(period: string, cap: number): Promise<Consumed> {
    return this.record.consume(period, cap);
  }
  async consumeTrial(period: string, network: string, networkCap: number, cap: number): Promise<TrialConsumed> {
    const r = await this.trial.consume(period, network, networkCap, cap);
    if (r.ok && (await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(nextDay(new Date()));
    return r;
  }
  spendTrial(period: string, cap: number): Promise<Consumed> {
    return this.trial.spend(period, cap);
  }
  releaseTrial(period: string, network: string): Promise<void> {
    return this.trial.release(period, network);
  }
  async alarm(): Promise<void> {
    await this.ctx.storage.delete(NETWORKS_KEY);
  }
}
