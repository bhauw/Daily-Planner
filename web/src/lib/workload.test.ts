/*
 * One workload reading and one clock, everywhere.
 *
 * Tasks and Today said "Moderate · 4 blocks" while the Calendar's Day view said
 * "Calm · 4 blocks" for the same day: each computed committed minutes over the
 * window it happened to DRAW (09–21 vs 07–21), so the same minutes gave a
 * different ratio. And the Calendar wrote "9 AM" / "2 PM" beside Tasks' and the
 * Dayline's "09:00" / "14:00" on the same screen.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import type { PlannerEvent } from "../api/client";
import { Dayline } from "../components/Dayline";
import { formatTime } from "./format";
import { workloadFor } from "./workload";
import { fmtMinutes } from "../workspaces/calendar/scheduling";

const at = (hm: string) => `2026-09-14T${hm}:00-07:00`;
const ev = (id: string, s: string, e: string) =>
  ({ id, calendarId: "c", title: id, category: "school", kind: "event", start: at(s), end: at(e), due: null, location: null }) as PlannerEvent;

const day = [ev("a", "09:00", "10:20"), ev("b", "11:00", "12:00"), ev("c", "13:00", "14:30"), ev("d", "15:00", "16:30")];

async function detailFor(windowStart: number, windowEnd: number): Promise<string> {
  const host = document.createElement("div");
  const root = createRoot(host);
  await act(async () => root.render(createElement(Dayline, { events: day, windowStart, windowEnd })));
  const text = host.querySelector(".pressure__detail")?.textContent ?? "";
  act(() => root.unmount());
  return text;
}

describe("the workload meter", () => {
  it("reads the same for the same day whatever window the timeline draws", async () => {
    expect(await detailFor(7 * 60, 21 * 60)).toBe(await detailFor(9 * 60, 21 * 60));
  });

  it("is one function: committed minutes over the planning day", () => {
    const w = workloadFor(day);
    expect(w.count).toBe(4);
    expect(w.value).toBeCloseTo((80 + 60 + 90 + 90) / (12 * 60));
    expect(w.word).toBe("Moderate");
  });
});

describe("one clock format", () => {
  it("the Calendar's minute labels match the app's formatTime", () => {
    expect(fmtMinutes(9 * 60)).toBe(formatTime(at("09:00")));
    expect(fmtMinutes(14 * 60 + 15)).toBe(formatTime(at("14:15")));
  });
});
