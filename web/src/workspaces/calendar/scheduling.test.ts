/*
 * Availability: never offer a time that has already gone, and say truthfully
 * what each slot is bounded by.
 *
 * findAvailability had no "now" floor, so at 15:00 it still ranked today's
 * 12:15 as the #1 slot. And its reason picked the nearest earlier IN-PERSON
 * event, so a 12:15 slot said "30 min transit from AQ 3150" — a lecture that
 * ended at 10:20 — when the real constraint was the buffer after the 11:00
 * focus block.
 */

import { describe, expect, it } from "vitest";
import type { PlannerEvent } from "../contract";
import { findAvailability } from "./scheduling";

const MON = "2026-09-14";
const at = (day: string, hm: string) => `${day}T${hm}:00-07:00`;

function ev(id: string, title: string, s: string, e: string, location: string | null = null): PlannerEvent {
  return { id, calendarId: "c1", title, category: "school", kind: "event", start: at(MON, s), end: at(MON, e), due: null, location } as PlannerEvent;
}

const day = [
  ev("lec", "ECONOMICS 250 Lecture", "09:00", "10:20", "AQ 3150"),
  { ...ev("focus", "Focus — Assignment 3", "11:00", "12:00"), kind: "deadline" } as PlannerEvent,
];

describe("findAvailability and the clock", () => {
  it("offers nothing today that starts before now", () => {
    const slots = findAvailability(day, MON, 45, 1, new Date(at(MON, "15:00")));
    expect(slots.length).toBeGreaterThan(0);
    for (const s of slots.filter((x) => x.dayKey === MON)) expect(s.start).toBeGreaterThanOrEqual(15 * 60);
  });

  it("does not offer yesterday when the window starts before today", () => {
    const slots = findAvailability(day, "2026-09-11", 45, 7, new Date(at(MON, "08:00")));
    expect(slots.every((s) => s.dayKey >= MON)).toBe(true);
  });

  it("without a clock, behaves as before (the whole window)", () => {
    const first = findAvailability(day, MON, 45, 1)[0];
    expect(first.start).toBe(12 * 60 + 15);
  });
});

describe("slot reasons name what actually bounds the slot", () => {
  it("blames the focus block's buffer, not a lecture that ended hours earlier", () => {
    const slot = findAvailability(day, MON, 45, 1).find((s) => s.start === 12 * 60 + 15)!;
    const text = slot.reasons.join(" | ");
    expect(text).toContain("Focus — Assignment 3");
    expect(text).not.toContain("AQ 3150");
  });

  it("names travel from the venue when the bounding event IS in person", () => {
    const slot = findAvailability([day[0]], MON, 30, 1)[0];
    expect(slot.start).toBe(10 * 60 + 50);
    expect(slot.reasons.join(" | ")).toContain("AQ 3150");
  });

  it("does not repeat the same boilerplate on every slot", () => {
    const slots = findAvailability(day, MON, 45, 1);
    for (const s of slots) expect(s.reasons.join(" ")).not.toContain("Clear of the prior meeting's buffer");
  });
});
