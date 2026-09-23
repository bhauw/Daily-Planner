/*
 * Offer times, the pure half: which slots, and what is sent.
 *
 * Two promises are pinned here because both fail silently in the UI. A wrong slot looks exactly
 * like a right one until the recruiter turns up to a class; a leaked event title looks like
 * nothing at all, because it leaves in a request body nobody reads.
 */

import { describe, expect, it } from "vitest";
import type { PlannerEvent } from "../api/client";
import { findAvailability } from "../workspaces/calendar/scheduling";
import { isoAtVan } from "../workspaces/calendar/tz";
import {
  businessDaysAhead,
  buildOfferInstruction,
  MAX_INSTRUCTION_BYTES,
  slotLine,
  suggestSlots,
} from "./offerSlots";

// Wednesday 23 Sep 2026; the week read covers today plus six days, as /api/week does.
const WINDOW = { start: "2026-09-23", days: 7 };

function ev(id: string, day: number, from: [number, number], to: [number, number], extra: Partial<PlannerEvent> = {}): PlannerEvent {
  return {
    id,
    title: `Event ${id}`,
    category: "career",
    kind: "event",
    start: isoAtVan(2026, 9, day, from[0], from[1]),
    end: isoAtVan(2026, 9, day, to[0], to[1]),
    due: null,
    location: null,
    calendarId: "primary",
    ...extra,
  };
}

// Private details that must never reach the assistant.
const SECRET_TITLE = "Confidential — Example Corp partner interview";
const SECRET_PLACE = "PwC Tower, 12th floor";
const EVENTS: PlannerEvent[] = [
  ev("a", 24, [9, 0], [12, 0], { title: SECRET_TITLE, location: SECRET_PLACE }),
  ev("b", 24, [13, 0], [14, 0], { title: "ECONOMICS 250 Lecture", category: "school" }),
  ev("c", 25, [9, 0], [18, 0], { title: "All-day audit shadow" }), // Friday fully booked in hours
  ev("d", 28, [10, 0], [11, 0], { title: "Investment Club", location: "SUB 2270" }),
];

describe("which days are searched", () => {
  it("starts tomorrow, skips the weekend and stops where the calendar read stops", () => {
    const { days, clipped } = businessDaysAhead(WINDOW, 5);
    expect(days).toEqual(["2026-09-24", "2026-09-25", "2026-09-28", "2026-09-29"]);
    // Wednesday 30th is outside the read: an unread day looks free, so it is never searched.
    expect(clipped).toBe(true);
  });

  it("is not clipped when the read covers the horizon", () => {
    expect(businessDaysAhead(WINDOW, 3)).toEqual({ days: ["2026-09-24", "2026-09-25", "2026-09-28"], clipped: false });
  });
});

describe("suggestSlots", () => {
  it("offers only slots findAvailability produced for the same events, length and days", () => {
    const { slots, searched } = suggestSlots(EVENTS, WINDOW, 45, 5);
    const engine = findAvailability(EVENTS, searched[0], 45, 6);
    expect(slots.length).toBeGreaterThanOrEqual(3);
    expect(slots.length).toBeLessThanOrEqual(5);
    for (const s of slots) expect(engine).toContainEqual(s);
  });

  it("spreads across days before taking a second slot on any one", () => {
    const { slots } = suggestSlots(EVENTS, WINDOW, 45, 5);
    const firstDays = new Set(slots.slice(0, 3).map((s) => s.dayKey));
    // Thu, Mon, Tue have normal-hours openings; the first three suggestions are three days.
    expect(firstDays.size).toBe(3);
  });

  it("keeps the engine's buffers: nothing lands on or beside a commitment", () => {
    const { slots } = suggestSlots(EVENTS, WINDOW, 45, 5);
    const thursday = slots.filter((s) => s.dayKey === "2026-09-24");
    // 9–12 in person (+30 buffer) and 13–14 virtual (+15): 12:30 is the first legal start.
    for (const s of thursday) {
      expect(s.start >= 12 * 60 + 30).toBe(true);
      expect(s.start + 45 <= 12 * 60 + 45 || s.start >= 14 * 60 + 15).toBe(true);
    }
  });

  it("uses the labelled evening fallback only on a day with no normal-hours opening", () => {
    const { slots } = suggestSlots(EVENTS, WINDOW, 45, 5, 50);
    const friday = slots.filter((s) => s.dayKey === "2026-09-25");
    expect(friday.length).toBeGreaterThan(0);
    expect(friday.every((s) => s.fallback)).toBe(true);
  });

  it("is empty, not invented, when nothing is free", () => {
    const busy = [24, 25, 28, 29].map((d) => ev(`x${d}`, d, [8, 0], [21, 0]));
    expect(suggestSlots(busy, WINDOW, 30, 5).slots).toEqual([]);
  });
});

describe("buildOfferInstruction", () => {
  const { slots } = suggestSlots(EVENTS, WINDOW, 45, 5);

  it("lists each ticked slot with its day, time and zone", () => {
    const built = buildOfferInstruction(slots.slice(0, 3), 45)!;
    expect(built.offered).toBe(3);
    for (const s of slots.slice(0, 3)) expect(built.instruction).toContain(`- ${slotLine(s)}`);
    expect(built.instruction).toMatch(/45-minute/);
    expect(built.instruction).toMatch(/PDT/);
  });

  it("carries no event title, venue or reason — only times leave the Mac", () => {
    const built = buildOfferInstruction(slots, 45)!;
    for (const e of EVENTS) {
      expect(built.instruction).not.toContain(e.title);
      if (e.location) expect(built.instruction).not.toContain(e.location);
    }
    // Reasons can name a venue ("transit from …"); they are for the picker only.
    for (const s of slots) for (const r of s.reasons) expect(built.instruction).not.toContain(r);
    expect(built.instruction).not.toMatch(/Example Corp|PwC|SUB 2270|ECONOMICS 250|transit/i);
  });

  it("never exceeds the engine's byte limit, dropping trailing slots to fit", () => {
    const many = Array.from({ length: 40 }, (_, i) => ({ ...slots[0], start: slots[0].start + i }));
    const built = buildOfferInstruction(many, 45)!;
    expect(new TextEncoder().encode(built.instruction).length).toBeLessThanOrEqual(MAX_INSTRUCTION_BYTES);
    expect(built.offered).toBeLessThan(40);
    expect(built.offered).toBeGreaterThan(0);
  });

  it("refuses to build an empty offer", () => {
    expect(buildOfferInstruction([], 45)).toBeNull();
  });

  it("marks a fallback slot as evening", () => {
    const fb = suggestSlots(EVENTS, WINDOW, 45, 5, 50).slots.find((s) => s.fallback)!;
    expect(buildOfferInstruction([fb], 45)!.instruction).toMatch(/PM PDT \(evening\)/);
  });
});
