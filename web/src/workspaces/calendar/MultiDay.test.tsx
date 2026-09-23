/*
 * Events that cross midnight (t7 edge report, P0).
 *
 * eventInterval took minutes-of-day for both ends and clamped end to start with
 * Math.max, so a 23:45 → 06:10(+2d) red-eye became a zero-length event and drew
 * as a 20px sliver. And every grid filed an event under its START day only, so
 * the days it continued into showed nothing at all.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Api, PlannerEvent } from "../contract";
import CalendarWorkspace from "./index";
import { busyForDay, eventInterval, intervalOnDay } from "./scheduling";
import { WINDOW_START, WINDOW_END, PX_PER_MIN } from "./layout";

const at = (day: string, hm: string) => `${day}T${hm}:00-07:00`;
const ev = (id: string, title: string, s: string, e: string): PlannerEvent =>
  ({ id, calendarId: "c1", title, category: "school", kind: "event", start: s, end: e, due: null, location: null }) as PlannerEvent;

const MON = "2026-09-14";
const TUE = "2026-09-15";
const WED = "2026-09-16";
const nightShift = ev("z2", "Night shift across midnight", at(MON, "22:30"), at(TUE, "01:30"));
const redEye = ev("z3", "Red-eye flight YVR→CGK", at(MON, "23:45"), at(WED, "06:10"));
const lateLab = ev("z5", "Late lab", at(TUE, "19:00"), at(WED, "08:00"));

describe("eventInterval and per-day segments", () => {
  it("measures a midnight-crossing event from its real duration, not clamped to zero", () => {
    const iv = eventInterval(redEye)!;
    expect(iv.end - iv.start).toBe(30 * 60 + 25);
  });

  it("splits a multi-day event into the part on each calendar day", () => {
    expect(intervalOnDay(redEye, MON)).toEqual({ start: 23 * 60 + 45, end: 24 * 60 });
    expect(intervalOnDay(redEye, TUE)).toEqual({ start: 0, end: 24 * 60 });
    expect(intervalOnDay(redEye, WED)).toEqual({ start: 0, end: 6 * 60 + 10 });
    expect(intervalOnDay(redEye, "2026-09-17")).toBeNull();
  });

  it("counts an event as busy on the days it continues into", () => {
    expect(busyForDay([nightShift], TUE).map((b) => b.interval)).toEqual([{ start: 0, end: 90 }]);
  });

  it("does not spill onto the next day when it ends exactly at midnight", () => {
    const toMidnight = ev("m", "Ends at midnight", at(MON, "22:00"), at(TUE, "00:00"));
    expect(intervalOnDay(toMidnight, TUE)).toBeNull();
  });
});

const fakeApi = {
  preview: async () => ({ day: TUE, schedule: [], queue: [] }),
  week: async () => ({ start: MON, days: 7, events: [nightShift, redEye, lateLab] }),
  calendars: async () => ({ calendars: [{ id: "c1", title: "School", role: "planning" }] }),
} as unknown as Api;

let roots: Root[] = [];
afterEach(() => {
  act(() => roots.forEach((r) => r.unmount()));
  roots = [];
  document.body.innerHTML = "";
});

async function mount() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  roots.push(root);
  await act(async () => {
    root.render(createElement(CalendarWorkspace, { api: fakeApi, day: TUE, detached: false }));
  });
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
  return host;
}

const blockIn = (col: Element, title: string) =>
  [...col.querySelectorAll<HTMLElement>("button.cal-blk")].find((b) => b.getAttribute("aria-label")?.startsWith(title));

describe("the Week grid draws each day's part of a multi-day event", () => {
  it("shows the red-eye on Tuesday as the whole visible day, not a sliver", async () => {
    const host = await mount();
    const tue = host.querySelectorAll(".daycol")[2]; // Sun 13 · Mon 14 · Tue 15
    const block = blockIn(tue, "Red-eye flight")!;
    expect(block).toBeDefined();
    expect(block.style.top).toBe("0px");
    expect(block.style.height).toBe(`${(WINDOW_END - WINDOW_START) * PX_PER_MIN}px`);
  });

  it("draws an evening-to-morning event down to the end of the window on its first day", async () => {
    const host = await mount();
    const tue = host.querySelectorAll(".daycol")[2];
    const block = blockIn(tue, "Late lab")!;
    expect(block.style.top).toBe(`${(19 * 60 - WINDOW_START) * PX_PER_MIN}px`);
    expect(block.style.height).toBe(`${(WINDOW_END - 19 * 60) * PX_PER_MIN}px`);
    // …and its morning on Wednesday.
    const wed = host.querySelectorAll(".daycol")[3];
    expect(blockIn(wed, "Late lab")?.style.height).toBe(`${(8 * 60 - WINDOW_START) * PX_PER_MIN}px`);
  });
});

describe("Month and Day views include the days an event continues into", () => {
  it("Month counts the red-eye on Wednesday", async () => {
    const host = await mount();
    await act(async () => [...host.querySelectorAll("button")].find((b) => b.textContent === "Month")!.click());
    const wedCell = [...host.querySelectorAll<HTMLElement>("[aria-label]")].find((el) =>
      /^Wednesday \w+ 16,/.test(el.getAttribute("aria-label") ?? ""),
    );
    expect(wedCell?.getAttribute("aria-label")).toMatch(/2 events/);
  });

  it("Day view for Tuesday lists the night shift that started Monday", async () => {
    const host = await mount();
    await act(async () => [...host.querySelectorAll("button")].find((b) => b.textContent === "Day")!.click());
    expect(host.querySelector(".dayview")?.textContent).toContain("Night shift across midnight");
  });
});
