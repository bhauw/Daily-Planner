/*
 * The one write in Plan my day. Pinned: creates run in order, one per row, never retried; a
 * partial failure is reported per row; an unreadable receipt is flagged as possibly written; and
 * an account-wide refusal stops the batch instead of repeating itself N times.
 */

import { describe, expect, it, vi } from "vitest";
import { ApiError, type CreateEventRequest } from "../../api/client";
import { createInSequence, summarise } from "./commit";

const req = (title: string): CreateEventRequest => ({ title, start: "2026-09-14T16:00:00Z", end: "2026-09-14T17:00:00Z" });
const ok = (r: CreateEventRequest) => Promise.resolve({ ok: true, id: `id-${r.title}`, start: r.start, end: r.end, htmlLink: null });

describe("createInSequence", () => {
  it("creates each row once, in order, and reports each", async () => {
    const order: string[] = [];
    const create = vi.fn(async (r: CreateEventRequest) => {
      order.push(r.title);
      return ok(r);
    });
    const results = await createInSequence([req("a"), req("b"), req("c")], create);
    expect(create).toHaveBeenCalledTimes(3);
    expect(order).toEqual(["a", "b", "c"]);
    expect(results.map((r) => r.state)).toEqual(["created", "created", "created"]);
    expect(summarise(results).text).toBe("All 3 added to your calendar.");
  });

  it("carries on past a row failure and names the failing row, without retrying it", async () => {
    const create = vi.fn(async (r: CreateEventRequest) => {
      if (r.title === "b") throw new ApiError("provider_refused", "Google would not accept that.");
      return ok(r);
    });
    const results = await createInSequence([req("a"), req("b"), req("c")], create);
    expect(create).toHaveBeenCalledTimes(3);
    expect(results.map((r) => r.state)).toEqual(["created", "failed", "created"]);
    expect(results[1]).toMatchObject({ message: "Google would not accept that.", ambiguous: false });
    expect(summarise(results).text).toBe("2 of 3 added. 1 not added — each is marked below.");
  });

  it("marks an unreadable receipt as possibly written and never retries it", async () => {
    const create = vi.fn(async () => {
      throw new ApiError("bad_response", "The engine returned an unexpected response.");
    });
    const [result] = await createInSequence([req("a")], create);
    expect(create).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ state: "failed", ambiguous: true });
    expect(result.message).toMatch(/may have been added/);
  });

  it("stops at an account-wide refusal and marks the rest as not tried", async () => {
    const create = vi.fn(async () => {
      throw new ApiError("write_not_permitted", "This account is connected for reading only.");
    });
    const results = await createInSequence([req("a"), req("b"), req("c")], create);
    expect(create).toHaveBeenCalledTimes(1);
    expect(results.map((r) => r.state)).toEqual(["failed", "skipped", "skipped"]);
    expect(results[1].message).toBe("Not tried — this account is connected for reading only.");
    expect(summarise(results).text).toBe("None of the 3 were added.");
  });

  it("reports progress row by row", async () => {
    const seen: string[] = [];
    await createInSequence([req("a"), req("b")], ok, (i, r) => seen.push(`${i}:${r.state}`));
    expect(seen).toEqual(["0:creating", "0:created", "1:creating", "1:created"]);
  });
});
