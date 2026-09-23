/*
 * The "does today fit?" arithmetic. Pinned: free time is only usable gaps inside working hours;
 * placement never overlaps anything already on the day and never goes below MIN_BLOCK_MIN; the
 * meter is exactly planned-against-free; and what does not fit is reported, not squeezed.
 */

import { describe, expect, it } from "vitest";
import type { PlannerEvent } from "../../api/client";
import { MIN_BLOCK_MIN } from "../../workspaces/tasks/insertion";
import {
  candidates,
  fitPlan,
  formatMinutes,
  freeGaps,
  freeMinutes,
  planningWindow,
  toRequests,
  WORK_END,
  WORK_START,
  type Pick,
} from "./model";

const DAY = "2026-09-14";
const at = (hhmm: string) => `${DAY}T${hhmm}:00-07:00`;

function ev(id: string, start: string, end: string | null, kind: PlannerEvent["kind"] = "event"): PlannerEvent {
  return { id, title: id, category: "school", kind, start: at(start), end: end ? at(end) : null, due: null, location: null, calendarId: "primary" };
}

const pick = (id: string, minutes: number): Pick => ({ id, title: id, minutes, category: "school", taskId: id });

// The mock day: lecture 09:00–10:20, focus 11:00–12:00, coffee 13:30–14:15, club 15:00–16:00.
const DAYLINE = [ev("lec", "09:00", "10:20"), ev("focus", "11:00", "12:00", "deadline"), ev("coffee", "13:30", "14:15"), ev("club", "15:00", "16:00")];
const WHOLE = { startMin: WORK_START, endMin: WORK_END };

function mins(iso: string): number {
  const d = new Date(iso);
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Vancouver", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(d);
  return Number(parts.find((p) => p.type === "hour")!.value) * 60 + Number(parts.find((p) => p.type === "minute")!.value);
}

describe("free time", () => {
  it("is the usable gaps between blocks inside working hours", () => {
    const gaps = freeGaps(DAYLINE, WHOLE);
    expect(gaps.map((g) => [g.startMin, g.endMin])).toEqual([
      [620, 660], // 10:20–11:00
      [720, 810], // 12:00–13:30
      [855, 900], // 14:15–15:00
      [960, 1260], // 16:00–21:00
    ]);
    expect(freeMinutes(gaps)).toBe(40 + 90 + 45 + 300);
  });

  it("leaves out slivers too short for a block, so the meter never promises unusable room", () => {
    const gaps = freeGaps([ev("a", "09:00", "10:00"), ev("b", "10:10", "21:00")], WHOLE);
    expect(gaps).toEqual([]);
    expect(freeMinutes(gaps)).toBe(0);
  });

  it("does not treat an open-ended deadline as busy time", () => {
    const gaps = freeGaps([ev("due", "14:00", null, "deadline")], WHOLE);
    expect(freeMinutes(gaps)).toBe(WORK_END - WORK_START);
  });

  it("starts at now (rounded up to the quarter hour) on the day itself, and not on other days", () => {
    const now = new Date(at("10:43"));
    expect(planningWindow(DAY, now)).toEqual({ startMin: 10 * 60 + 45, endMin: WORK_END });
    expect(planningWindow("2026-09-15", now)).toEqual(WHOLE);
    expect(planningWindow(DAY, new Date(at("06:00")))).toEqual(WHOLE);
    expect(planningWindow(DAY, new Date(at("22:30")))).toEqual({ startMin: WORK_END, endMin: WORK_END });
  });
});

describe("fitting picks into the day", () => {
  it("places first-fit in pick order and never overlaps anything already there", () => {
    const gaps = freeGaps(DAYLINE, WHOLE);
    const fit = fitPlan([pick("a", 60), pick("b", 30), pick("c", 90)], gaps);
    expect(fit.overflow).toEqual([]);
    const byId = Object.fromEntries(fit.placed.map((p) => [p.pick.id, [p.startMin, p.endMin]]));
    expect(byId).toEqual({ a: [720, 780], b: [620, 650], c: [960, 1050] });

    // Property-style: across many random plans, no placed block overlaps an obstacle or another
    // block, stays inside working hours, and is at least MIN_BLOCK_MIN long.
    const sizes = [15, 30, 60, 90];
    let seed = 7;
    const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    const busy = DAYLINE.map((e) => [mins(e.start), mins(e.end!)]);
    for (let run = 0; run < 200; run++) {
      const picks = Array.from({ length: 1 + Math.floor(rand() * 10) }, (_, i) => pick(`p${i}`, sizes[Math.floor(rand() * 4)]));
      const f = fitPlan(picks, gaps);
      expect(f.placed.length + f.overflow.length).toBe(picks.length);
      for (const p of f.placed) {
        expect(p.endMin - p.startMin).toBeGreaterThanOrEqual(MIN_BLOCK_MIN);
        expect(p.startMin).toBeGreaterThanOrEqual(WORK_START);
        expect(p.endMin).toBeLessThanOrEqual(WORK_END);
        for (const [s, e] of busy) expect(p.startMin < e && s < p.endMin).toBe(false);
        for (const q of f.placed) if (q !== p) expect(p.startMin < q.endMin && q.startMin < p.endMin).toBe(false);
      }
    }
  });

  it("raises a pick below the floor to MIN_BLOCK_MIN rather than placing a sliver", () => {
    const fit = fitPlan([pick("tiny", 5)], freeGaps([], WHOLE));
    expect(fit.placed[0].endMin - fit.placed[0].startMin).toBe(MIN_BLOCK_MIN);
    expect(fit.plannedMin).toBe(MIN_BLOCK_MIN);
  });

  it("reports the meter as planned against free, amber past 85% and red once over", () => {
    const gaps = freeGaps([ev("x", "09:00", "17:00")], WHOLE); // 17:00–21:00 = 240 free
    expect(fitPlan([], gaps).level).toBe("empty");
    expect(fitPlan([pick("a", 60)], gaps)).toMatchObject({ plannedMin: 60, freeMin: 240, level: "ok" });
    expect(fitPlan([pick("a", 90), pick("b", 90), pick("c", 30)], gaps)).toMatchObject({ plannedMin: 210, level: "tight" });
    const over = fitPlan([pick("a", 90), pick("b", 90), pick("c", 90)], gaps);
    expect(over).toMatchObject({ plannedMin: 270, freeMin: 240, overByMin: 30, level: "over" });
    expect(over.overflow.map((p) => p.id)).toEqual(["c"]);
  });

  it("reports a pick that fits in total but in no single stretch, instead of splitting it", () => {
    const gaps = freeGaps([ev("a", "09:00", "10:00"), ev("b", "10:45", "20:15")], WHOLE); // 45 + 45 free
    const fit = fitPlan([pick("long", 60)], gaps);
    expect(fit.level).toBe("ok");
    expect(fit.placed).toEqual([]);
    expect(fit.overflow.map((p) => p.id)).toEqual(["long"]);
  });

  it("says the day is full when there is no usable free time at all", () => {
    const fit = fitPlan([pick("a", 30)], freeGaps([ev("all", "08:00", "22:00")], WHOLE));
    expect(fit.level).toBe("full");
    expect(fit.overflow).toHaveLength(1);
  });
});

describe("what would be written", () => {
  it("builds one zone-correct request per placed block, with no calendar id", () => {
    const fit = fitPlan([pick("Essay", 60)], freeGaps([], WHOLE));
    const [req] = toRequests(fit.placed, DAY);
    expect(req.title).toBe("Focus — Essay");
    expect(new Date(req.start).toISOString()).toBe("2026-09-14T16:00:00.000Z"); // 09:00 PDT
    expect(new Date(req.end).toISOString()).toBe("2026-09-14T17:00:00.000Z");
    expect(req).not.toHaveProperty("calendarId");
    // Standard time: the same wall clock is −08:00 in January, which a hardcoded offset gets wrong.
    const [winter] = toRequests(fit.placed, "2026-01-16");
    expect(new Date(winter.start).toISOString()).toBe("2026-01-16T17:00:00.000Z");
  });

  it("formats minutes the way he estimated them", () => {
    expect(formatMinutes(0)).toBe("0m");
    expect(formatMinutes(45)).toBe("45m");
    expect(formatMinutes(120)).toBe("2h");
    expect(formatMinutes(195)).toBe("3h 15m");
  });
});

describe("candidates", () => {
  it("lists open tasks in Focus order, pinning anything due today or earlier", () => {
    const lists = [
      { name: "School", items: [
        { id: "later", title: "Later", category: "school" as const, due: null, done: false },
        { id: "late", title: "Late", category: "school" as const, due: at("08:00"), done: false },
        { id: "done", title: "Done", category: "school" as const, due: null, done: true },
      ] },
    ];
    const out = candidates(lists, new Date(at("10:00")));
    expect(out.map((c) => [c.id, c.pinned])).toEqual([["late", true], ["later", false]]);
    expect(out[0].list).toBe("School");
  });
});
