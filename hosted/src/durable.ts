// The two SQLite-backed Durable Objects. Each call is one storage read and at most one write; a
// Durable Object runs one call at a time, so a count can't be raced past its cap.

import { DurableObject } from "cloudflare:workers";
import { BudgetRecord, LicenseRecord, type Consumed, type Validity } from "./state";

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

/** A single instance ("global"): today's count of Anthropic calls, the cost circuit-breaker. */
export class GlobalBudget extends DurableObject {
  private readonly record = new BudgetRecord(this.ctx.storage);
  consume(period: string, cap: number): Promise<Consumed> {
    return this.record.consume(period, cap);
  }
}
