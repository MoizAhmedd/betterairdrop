import { describe, expect, it } from "vitest";
import { handle } from "../src/handler";
import { network } from "../src/request";
import { CONTEXT, GOOD_ANSWER, TRIAL_ID, body, granted, jpeg, message, request, world } from "./helpers";

const answerText = JSON.stringify(GOOD_ANSWER);
const trial = (opts: { id?: string; ip?: string; path?: string } = {}) =>
  request(opts.path === "/v1/name-text" ? { context: "PDF worked out on the user's Mac:", text: "INVOICE" } : undefined,
          { trial: opts.id ?? TRIAL_ID, ip: opts.ip, path: opts.path });
const otherId = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

describe("the free trial", () => {
  it("names a photo with no license and no Polar call, and says how many trial names are left", async () => {
    const w = world();
    w.net.anthropic.push(message(answerText));
    const res = await handle(trial(), w.deps);
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual(GOOD_ANSWER);
    expect(res.headers.get("x-trial-remaining")).toBe("24");
    expect(res.headers.get("x-names-remaining")).toBeNull();
    expect(w.net.polarCalls()).toHaveLength(0);
    expect(w.logs).toEqual([{ event: "request", status: 200, outcome: "trial_named" }]);
  });

  it("gives each trial ID 25 names for good, then 403 trial_used_up without calling Claude", async () => {
    const w = world({ trialCap: 2 });
    w.net.anthropic.push(message(answerText), message(answerText), message(answerText));
    expect((await handle(trial(), w.deps)).headers.get("x-trial-remaining")).toBe("1");
    expect((await handle(trial({ id: TRIAL_ID.toLowerCase() }), w.deps)).headers.get("x-trial-remaining")).toBe("0");
    w.clock.now = new Date("2027-03-01T12:00:00Z"); // a new day and month: still used up
    const res = await handle(trial(), w.deps);
    expect(res.status).toBe(403);
    expect((await body(res)).error.type).toBe("trial_used_up");
    expect(w.net.anthropicCalls()).toHaveLength(2);
    expect((await w.deps.trialBudget().spend("2027-03-01", 300)).used).toBe(1); // the refused one was given back
  });

  it("has its own daily cap, which never touches the paid one", async () => {
    const w = world({ trialDailyCap: 1, dailyCap: 1 });
    w.net.anthropic.push(message(answerText), message(answerText), message(answerText));
    expect((await handle(trial(), w.deps)).status).toBe(200);
    const res = await handle(trial({ id: otherId(1), ip: "198.51.100.9" }), w.deps);
    expect(res.status).toBe(429);
    const b = await body(res);
    expect(b.error.type).toBe("trial_daily_limit");
    expect(b.error.resets_at).toBe("2026-10-16T00:00:00Z");
    expect(res.headers.get("retry-after")).toBe(String(12 * 3600));
    expect(w.budget.writes).toBe(0);

    // A paying user still gets the whole paid cap.
    w.net.polar.push(granted);
    expect((await handle(request(), w.deps)).status).toBe(200);
    w.clock.now = new Date("2026-10-16T00:00:01Z");
    expect((await handle(trial({ id: otherId(1) }), w.deps)).status).toBe(200);
  });

  it("once the day's trial budget is spent, new IDs cost no writes", async () => {
    const w = world({ trialDailyCap: 1 });
    w.net.anthropic.push(message(answerText));
    await handle(trial(), w.deps);
    const writes = () => w.trialBudget.writes + [...w.licenses.values()].reduce((n, s) => n + s.writes, 0);
    const before = writes();
    for (let i = 0; i < 5; i++) expect((await handle(trial({ id: otherId(i) }), w.deps)).status).toBe(429);
    expect(writes()).toBe(before);
  });

  it("limits one network per day, by a salted hash of its IP (an IPv6 /64 counts as one)", async () => {
    const w = world({ trialNetworkDailyCap: 2 });
    for (let i = 0; i < 3; i++) w.net.anthropic.push(message(answerText));
    expect((await handle(trial({ id: otherId(1), ip: "2001:db8:aa:1::5" }), w.deps)).status).toBe(200);
    expect((await handle(trial({ id: otherId(2), ip: "2001:db8:aa:1:ffff::9" }), w.deps)).status).toBe(200);
    const res = await handle(trial({ id: otherId(3), ip: "2001:db8:aa:1::77" }), w.deps);
    expect(res.status).toBe(429);
    expect((await body(res)).error.type).toBe("trial_daily_limit");
    expect((await handle(trial({ id: otherId(3), ip: "198.51.100.9" }), w.deps)).status).toBe(200);

    const stored = JSON.stringify([...w.trialBudget.map]);
    expect(stored).not.toContain("2001:db8");
    expect(stored).not.toContain("198.51.100.9");
    expect(stored).not.toContain(TRIAL_ID);
  });

  it("the network hash changes with the day and the salt", async () => {
    const keys = async (salt: string, now: string) => {
      const w = world({ ipSalt: salt });
      w.clock.now = new Date(now);
      w.net.anthropic.push(message(answerText));
      await handle(trial(), w.deps);
      return Object.keys((w.trialBudget.map.get("networks") as { counts: Record<string, number> }).counts);
    };
    const today = await keys("a", "2026-10-15T12:00:00Z");
    expect(today).toEqual(await keys("a", "2026-10-15T18:00:00Z"));
    expect(today).not.toEqual(await keys("a", "2026-10-16T12:00:00Z"));
    expect(today).not.toEqual(await keys("b", "2026-10-15T12:00:00Z"));
  });

  it("is off without the salt, so no IP is ever used unsalted", async () => {
    const w = world({ ipSalt: undefined });
    const res = await handle(trial(), w.deps);
    expect(res.status).toBe(503);
    expect((await body(res)).error.type).toBe("trial_unavailable");
    expect(w.net.calls).toHaveLength(0);
    expect(w.trialBudget.writes).toBe(0);
  });

  it("names photos only, and only with a UUID", async () => {
    const w = world();
    const pdf = await handle(trial({ path: "/v1/name-text" }), w.deps);
    expect(pdf.status).toBe(403);
    expect((await body(pdf)).error.type).toBe("trial_photos_only");
    expect((await handle(trial({ id: "not-a-uuid" }), w.deps)).status).toBe(400);
    expect((await handle(request({ image: jpeg(1024, 768), context: CONTEXT }, { trial: TRIAL_ID }), w.deps)).status).toBe(413);
    expect(w.net.calls).toHaveLength(0);
  });

  it("a name that fails isn't counted against the ID; the structured retry spends the trial budget", async () => {
    const w = world({ trialCap: 1, trialDailyCap: 3 });
    w.net.anthropic.push({ status: 500, body: { type: "error", error: { type: "api_error", message: "boom" } } });
    expect((await handle(trial(), w.deps)).status).toBe(502);
    w.net.anthropic.push(message("Sure! It's a lamp."), message(answerText));
    const res = await handle(trial(), w.deps);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trial-remaining")).toBe("0");
    expect((await w.deps.trialBudget().spend("2026-10-15", 3)).ok).toBe(false); // 1 + 2 calls
    expect(w.budget.writes).toBe(0);
  });
});

describe("network", () => {
  it("keeps IPv4 as it is and cuts IPv6 to its /64", () => {
    expect(network("203.0.113.7")).toBe("203.0.113.7");
    expect(network("::ffff:203.0.113.7")).toBe("203.0.113.7");
    expect(network("2001:db8:aa:1::5")).toBe("2001:db8:aa:1::/64");
    expect(network("2001:0db8:00aa:0001:1:2:3:4")).toBe("2001:db8:aa:1::/64");
    expect(network("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(network(null)).toBe("unknown");
  });
});
