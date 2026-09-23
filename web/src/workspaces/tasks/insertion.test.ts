/*
 * The gap model behind dropping a task between two blocks.
 *
 * These assert the properties the drop depends on: that a gap's time comes from
 * the space between real blocks, that overlapping blocks cannot invent a gap,
 * that a gap too small to hold a block is never offered, and that a block never
 * opens longer than the gap it was dropped into.
 */

import { describe, expect, it } from "vitest";
import type { PlannerEvent } from "../contract";
import {
  chooseGap,
  describePlacement,
  firstOpening,
  overlapFor,
  gapsFor,
  gapFits,
  placementFor,
  MIN_BLOCK_MIN,
  PREFERRED_BLOCK_MIN,
} from "./insertion";

const DAY = "2026-09-21";
const WINDOW_START = 9 * 60;
const WINDOW_END = 21 * 60;

/** A block on the planning day, given in Vancouver wall-clock minutes. */
function ev(id: string, startMin: number, endMin: number): PlannerEvent {
  const at = (m: number) =>
    `${DAY}T${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}:00-07:00`;
  return {
    id,
    calendarId: "primary",
    title: id,
    category: "school",
    kind: "event",
    start: at(startMin),
    end: at(endMin),
    due: null,
    location: null,
  } as PlannerEvent;
}

const gaps = (events: PlannerEvent[]) => gapsFor(events, WINDOW_START, WINDOW_END);

describe("gapsFor", () => {
  it("gives an empty day one gap spanning the whole window", () => {
    const g = gaps([]);
    expect(g).toHaveLength(1);
    expect(g[0]).toMatchObject({ startMin: WINDOW_START, endMin: WINDOW_END, afterId: null, beforeId: null });
  });

  it("puts a gap before, between and after the day's blocks", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);
    expect(g).toHaveLength(3);
    expect(g[0]).toMatchObject({ startMin: 9 * 60, endMin: 10 * 60, afterId: null, beforeId: "a" });
    expect(g[1]).toMatchObject({ startMin: 11 * 60, endMin: 14 * 60, afterId: "a", beforeId: "b" });
    expect(g[2]).toMatchObject({ startMin: 15 * 60, endMin: 21 * 60, afterId: "b", beforeId: null });
  });

  it("reads the gap from the blocks, not from the cursor — 11:00-14:00 is three hours", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);
    expect(g[1].endMin - g[1].startMin).toBe(180);
  });

  it("merges overlapping blocks so no phantom gap appears between them", () => {
    // Two classes that overlap are ONE obstruction. Sorting alone would leave a
    // negative-length interval between them and call it free time.
    const g = gaps([ev("a", 10 * 60, 12 * 60), ev("b", 11 * 60, 13 * 60)]);
    expect(g).toHaveLength(2);
    expect(g[0]).toMatchObject({ startMin: 9 * 60, endMin: 10 * 60 });
    expect(g[1]).toMatchObject({ startMin: 13 * 60, endMin: 21 * 60, afterId: "a" });
  });

  it("is order-independent — unsorted input yields the same gaps", () => {
    const sorted = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);
    const shuffled = gaps([ev("b", 14 * 60, 15 * 60), ev("a", 10 * 60, 11 * 60)]);
    expect(shuffled).toEqual(sorted);
  });

  it("clips a block that straddles the window instead of dropping it", () => {
    const g = gaps([ev("early", 7 * 60, 10 * 60)]);
    // The gap list stays aligned with the blocks, so the (empty) interval before
    // the straddling block is still an entry — it simply cannot hold anything.
    expect(g).toHaveLength(2);
    expect(gapFits(g[0])).toBe(false);
    expect(g[1].startMin).toBe(10 * 60);
  });

  it("ignores a block wholly outside the planning window", () => {
    const g = gaps([ev("night", 22 * 60, 23 * 60)]);
    expect(g).toHaveLength(1);
    expect(g[0]).toMatchObject({ startMin: WINDOW_START, endMin: WINDOW_END });
  });

  it("treats an end-less event as occupying time rather than as a zero-width mark", () => {
    const open = { ...ev("x", 12 * 60, 13 * 60), end: null } as PlannerEvent;
    const g = gaps([open]);
    expect(g).toHaveLength(2);
    expect(g[1].startMin).toBe(12 * 60 + MIN_BLOCK_MIN);
  });

  it("merges back-to-back blocks — touching is not a gap you can drop into", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 11 * 60, 12 * 60)]);
    expect(g).toHaveLength(2);
    expect(g[1]).toMatchObject({ startMin: 12 * 60, endMin: 21 * 60 });
  });

  it("keeps a gap too short for a block, so it can be rejected rather than guessed at", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 11 * 60 + 10, 12 * 60)]);
    expect(g[1]).toMatchObject({ startMin: 11 * 60, endMin: 11 * 60 + 10 });
    expect(gapFits(g[1])).toBe(false);
  });
});

describe("chooseGap", () => {
  // 09:00-10:00 free | a | a 10-min seam | b | 12:00-16:00 free | c | 17:00-21:00 free
  const day = [ev("a", 10 * 60, 11 * 60), ev("b", 11 * 60 + 10, 12 * 60), ev("c", 16 * 60, 17 * 60)];

  it("returns the gap at the boundary the cursor picked", () => {
    expect(chooseGap(gaps(day), 2)?.startMin).toBe(12 * 60);
  });

  it("walks outward when the boundary's gap is too small to hold a block", () => {
    // Boundary 1 is the 10-minute seam between a and b — under MIN_BLOCK_MIN.
    const chosen = chooseGap(gaps(day), 1);
    expect(chosen).not.toBeNull();
    expect(gapFits(chosen!)).toBe(true);
    // Both neighbours are one step away; the earlier one wins.
    expect(chosen!.startMin).toBe(9 * 60);
  });

  it("returns null only when the day genuinely has no room", () => {
    const full = [ev("all", WINDOW_START, WINDOW_END)];
    expect(chooseGap(gaps(full), 0)).toBeNull();
  });

  it("clamps a boundary outside the list rather than returning nothing", () => {
    expect(chooseGap(gaps(day), 99)?.beforeId).toBeNull();
    expect(chooseGap(gaps(day), -5)?.startMin).toBe(9 * 60);
  });
});

describe("placementFor", () => {
  it("starts the block at the top of the gap", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);
    expect(placementFor(g[1]).startMin).toBe(11 * 60);
  });

  it("never opens longer than the gap it was dropped into", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 11 * 60 + 40, 13 * 60)]);
    const p = placementFor(g[1]);
    expect(p.durationMin).toBe(40);
    expect(p.startMin + p.durationMin).toBeLessThanOrEqual(g[1].endMin);
  });

  it("prefers an hour when the gap has room for one", () => {
    expect(placementFor(gaps([])[0]).durationMin).toBe(PREFERRED_BLOCK_MIN);
  });

  it("marks a gap bounded on both sides as between two blocks", () => {
    const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);
    expect(placementFor(g[1]).between).toBe(true);
    expect(placementFor(g[0]).between).toBe(false);
    expect(placementFor(g[2]).between).toBe(false);
  });
});

describe("describePlacement", () => {
  const g = gaps([ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)]);

  it("says where it slots and what time it takes", () => {
    expect(describePlacement(placementFor(g[1]))).toBe("Between these · 11:00–12:00");
  });

  it("names the ends of the day rather than claiming to be between blocks", () => {
    expect(describePlacement(placementFor(g[0]))).toContain("Before the first block");
    expect(describePlacement(placementFor(g[2]))).toContain("After the last block");
    expect(describePlacement(placementFor(gaps([])[0]))).toContain("On an open day");
  });
});

describe("the keyboard path's opening time (Block time)", () => {
  // The mock day: lecture 09:00–10:20, the existing focus block 11:00–12:00.
  const day = [ev("lecture", 9 * 60, 10 * 60 + 20), ev("focus", 11 * 60, 12 * 60)];

  it("opens on the first gap that holds an hour, not on a fixed 11:00", () => {
    const at = firstOpening(gapsFor(day, WINDOW_START, WINDOW_END));
    expect(at).toEqual({ startMin: 12 * 60, durationMin: 60 });
  });

  it("takes a shorter first gap when no gap holds the full hour", () => {
    const packed = [ev("a", 9 * 60, 10 * 60), ev("b", 10 * 60 + 40, 21 * 60)];
    expect(firstOpening(gapsFor(packed, WINDOW_START, WINDOW_END))).toEqual({ startMin: 10 * 60, durationMin: 40 });
  });

  it("is null on a day with no room at all", () => {
    expect(firstOpening(gapsFor([ev("all", 9 * 60, 21 * 60)], WINDOW_START, WINDOW_END))).toBeNull();
  });
});

describe("overlapFor — naming what a proposed block would sit on", () => {
  const day = [ev("ECONOMICS 250 Lecture", 9 * 60, 10 * 60 + 20), ev("Focus — Assignment 3", 11 * 60, 12 * 60)];

  it("names the block a proposal overlaps", () => {
    expect(overlapFor(day, 11 * 60, 12 * 60)?.title).toBe("Focus — Assignment 3");
  });

  it("is null when the proposal only touches a neighbour's edge", () => {
    expect(overlapFor(day, 10 * 60 + 20, 11 * 60)).toBeNull();
  });
});
