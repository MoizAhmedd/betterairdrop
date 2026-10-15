import Anthropic from "@anthropic-ai/sdk";
import type { Deps } from "../src/handler";
import { nameImage, nameText } from "../src/name";
import { validateWithPolar } from "../src/polar";
import { BudgetRecord, LicenseRecord, TrialBudgetRecord, type Storage } from "../src/state";

export class MemoryStorage implements Storage {
  readonly map = new Map<string, unknown>();
  writes = 0;
  async get<T>(k: string) {
    return structuredClone(this.map.get(k)) as T | undefined;
  }
  async put<T>(k: string, v: T) {
    this.writes += 1;
    this.map.set(k, structuredClone(v));
  }
}

/** A minimal JPEG: SOI, an APP0, a baseline SOF0 with this size, then filler up to `bytes`. */
export function jpeg(width: number, height: number, bytes = 2000): string {
  const head = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03,
    0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01];
  const out = new Uint8Array(Math.max(bytes, head.length + 2));
  out.set(head);
  out.set([0xff, 0xd9], out.length - 2);
  let s = "";
  for (const b of out) s += String.fromCharCode(b);
  return btoa(s);
}

export const CONTEXT = "Context worked out on the user's Mac:\n- captured: 2026-09-21 14:03\n- place: Toronto, CA (city only)\n- local kind guess: photo (default)";
export const KEY = "BA_1234ABCD-5678-EF90-1234-567890ABCDEF";
export const GOOD_ANSWER = { subject: "Walnut lamp on oak sideboard", kind: "photo", merchant: "", total: "", confidence: 0.92, people_present: false };

export const TRIAL_ID = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";

export function request(body: unknown = { image: jpeg(768, 576), context: CONTEXT },
                        opts: { key?: string | null; trial?: string; ip?: string; method?: string; path?: string; raw?: string } = {}) {
  const headers: Record<string, string> = { "content-type": "application/json" };
  const key = opts.key === undefined ? KEY : opts.key;
  if (opts.trial !== undefined) headers.authorization = `Trial ${opts.trial}`;
  else if (key !== null) headers.authorization = `Bearer ${key}`;
  headers["cf-connecting-ip"] = opts.ip ?? "203.0.113.7";
  const method = opts.method ?? "POST";
  return new Request(`https://api.betterairdrop.com${opts.path ?? "/v1/name"}`, {
    method,
    headers,
    body: method === "GET" ? undefined : (opts.raw ?? JSON.stringify(body)),
  });
}

export type Reply = { status: number; body?: unknown } | "network";

/** A fetch that answers from a queue per host and records every request. */
export class FakeNet {
  polar: Reply[] = [];
  anthropic: Reply[] = [];
  calls: { host: string; body: any; headers: Headers }[] = [];
  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const req = new Request(input, init);
    const host = new URL(req.url).host;
    const text = await req.text();
    this.calls.push({ host, body: text ? JSON.parse(text) : null, headers: req.headers });
    const queue = host === "api.anthropic.com" ? this.anthropic : this.polar;
    const r = queue.shift() ?? { status: 500, body: { error: "no reply queued" } };
    if (r === "network") throw new TypeError("fetch failed");
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status, headers: { "content-type": "application/json", "request-id": "req_1" } });
  };
  polarCalls() {
    return this.calls.filter((c) => c.host !== "api.anthropic.com");
  }
  anthropicCalls() {
    return this.calls.filter((c) => c.host === "api.anthropic.com");
  }
}

export function message(text: string, stop = "end_turn") {
  return {
    status: 200,
    body: {
      id: "msg_1", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: stop, stop_sequence: null,
      content: [{ type: "text", text }], usage: { input_tokens: 1500, output_tokens: 60 },
    },
  };
}

export const granted = { status: 200, body: { id: "lk_1", status: "granted", key: KEY, expires_at: null } };

export interface World {
  net: FakeNet;
  licenses: Map<string, MemoryStorage>;
  budget: MemoryStorage;
  trialBudget: MemoryStorage;
  clock: { now: Date };
  logs: Record<string, unknown>[];
  deps: Deps;
}

/** The real handler, Polar client and namer, over fake network and in-memory Durable Object storage. */
export function world(over: Partial<Deps> = {}): World {
  const net = new FakeNet();
  const licenses = new Map<string, MemoryStorage>();
  const budget = new MemoryStorage();
  const trialBudget = new MemoryStorage();
  const clock = { now: new Date("2026-10-15T12:00:00Z") };
  const logs: Record<string, unknown>[] = [];
  const anthropic = new Anthropic({ apiKey: "sk-ant-test", maxRetries: 0, fetch: net.fetch });
  const deps: Deps = {
    now: () => clock.now,
    monthlyCap: 500,
    dailyCap: 5000,
    license: (hash) => {
      if (!licenses.has(hash)) licenses.set(hash, new MemoryStorage());
      return new LicenseRecord(licenses.get(hash)!);
    },
    budget: () => new BudgetRecord(budget),
    validate: (key) => validateWithPolar(key, { api: "https://api.polar.sh", organizationId: "org-uuid", fetch: net.fetch, now: () => clock.now }),
    name: (image, context, mayRetry) => nameImage(anthropic, image, context, mayRetry),
    nameText: (context, text, mayRetry) => nameText(anthropic, context, text, mayRetry),
    log: (l) => logs.push(l),
    trialCap: 25,
    trialDailyCap: 300,
    trialNetworkDailyCap: 50,
    trial: (hash) => {
      if (!licenses.has(hash)) licenses.set(hash, new MemoryStorage());
      return new LicenseRecord(licenses.get(hash)!);
    },
    trialBudget: () => new TrialBudgetRecord(trialBudget),
    ipSalt: "test-salt",
    ...over,
  };
  return { net, licenses, budget, trialBudget, clock, logs, deps };
}

export async function body(res: Response): Promise<any> {
  return JSON.parse(await res.text());
}
