/*
 * The Calendar's reschedule loop, mounted whole: propose → approve → the block
 * is where it was approved to, in every view.
 *
 * Approving used to delete the proposal and keep only the event's id, so the
 * panel fell back to the ORIGINAL start ("Accepted locally at 11:00" after
 * approving 14:00) and the Week grid drew the block back where it came from.
 * A cross-day drag named no day at all, and could only be approved from the Day
 * view of the source day.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Api, PlannerEvent } from "../contract";
import CalendarWorkspace from "./index";
import { WINDOW_START, PX_PER_MIN } from "./layout";
import { fmtMinutes } from "./scheduling";

const t = (h: number, m = 0) => fmtMinutes(h * 60 + m);

const TUE = "2026-09-15";
const at = (day: string, hm: string) => `${day}T${hm}:00-07:00`;

const lecture: PlannerEvent = {
  id: "lec", calendarId: "c1", title: "ECONOMICS 250 Lecture", category: "school", kind: "event",
  start: at(TUE, "09:00"), end: at(TUE, "10:20"), due: null, location: "AQ 3150",
} as PlannerEvent;
const focus: PlannerEvent = {
  id: "focus", calendarId: "c1", title: "Focus — Assignment 3", category: "school", kind: "deadline",
  start: at(TUE, "11:00"), end: at(TUE, "12:00"), due: null, location: null,
} as PlannerEvent;

const fakeApi = {
  preview: async () => ({ day: TUE, schedule: [lecture, focus], queue: [] }),
  week: async () => ({ start: TUE, days: 7, events: [lecture, focus] }),
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

const byLabel = (host: HTMLElement, re: RegExp) =>
  [...host.querySelectorAll<HTMLElement>("[aria-label]")].find((el) => re.test(el.getAttribute("aria-label") ?? ""));
const button = (root: ParentNode, text: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === text);

function fireDrag(target: Element, type: string, clientY = 0) {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientY });
  Object.defineProperty(e, "dataTransfer", { value: { setData() {}, effectAllowed: "", dropEffect: "" } });
  target.dispatchEvent(e);
}

/** Drag the focus block into a day's column at a wall-clock minute. */
async function dragFocusTo(host: HTMLElement, dayIndex: number, minute: number) {
  const block = byLabel(host, /^Focus — Assignment 3/)!;
  const col = host.querySelectorAll(".daycol")[dayIndex];
  await act(async () => {
    fireDrag(block, "dragstart");
    fireDrag(col, "dragover", (minute - WINDOW_START) * PX_PER_MIN);
    fireDrag(col, "drop", (minute - WINDOW_START) * PX_PER_MIN);
  });
}

describe("approving a reschedule keeps the approved time", () => {
  it("draws the block at the approved time in Week, and says that time in Day", async () => {
    const host = await mount();
    // Sun 13 … Sat 19: Tuesday is column 2.
    await dragFocusTo(host, 2, 14 * 60);
    const ghost = host.querySelector(".cal-blk--proposed") as HTMLElement;
    expect(ghost).not.toBeNull();
    // Approvable right here in the Week view.
    await act(async () => button(ghost, "Approve")!.click());

    // Drawn at 14:00 — not snapped back to 11:00.
    expect(byLabel(host, /^Focus — Assignment 3/)?.style.top).toBe(`${(14 * 60 - WINDOW_START) * PX_PER_MIN}px`);

    await act(async () => button(host, "Day")!.click());
    const note = [...host.querySelectorAll(".proposal__note")].map((n) => n.textContent).join(" ");
    expect(note).toContain(`Accepted locally at ${t(14)}`);
    expect(note).not.toContain(t(11));
  });
});

describe("a cross-day drag says which day it goes to", () => {
  it("names both days in the proposal, and keeps the target day on a ±15 nudge", async () => {
    const host = await mount();
    await dragFocusTo(host, 3, 14 * 60); // Wednesday
    await act(async () => button(host, "Day")!.click());
    const diff = host.querySelector(".proposal__diff")?.textContent ?? "";
    expect(diff).toContain(`Tue ${t(11)}`);
    expect(diff).toContain(`Wed ${t(14)}`);

    await act(async () => byLabel(host, /15 minutes later/)!.click());
    expect(host.querySelector(".proposal__diff")?.textContent).toContain(`Wed ${t(14, 15)}`);
  });

  it("can be approved from the Week ghost on the target day", async () => {
    const host = await mount();
    await dragFocusTo(host, 3, 14 * 60);
    const cols = host.querySelectorAll(".daycol");
    const ghost = cols[3].querySelector(".cal-blk--proposed") as HTMLElement;
    expect(ghost.getAttribute("aria-label")).toContain("Wed");
    await act(async () => button(ghost, "Approve")!.click());
    // The block now lives in Wednesday's column.
    expect(cols[3].querySelector('[aria-label^="Focus — Assignment 3"]')).not.toBeNull();
    expect(cols[2].querySelector('[aria-label^="Focus — Assignment 3"]')).toBeNull();
  });
});

describe("week-grid labels", () => {
  it("say which day each block is on", async () => {
    const host = await mount();
    expect(byLabel(host, /^ECONOMICS 250 Lecture/)?.getAttribute("aria-label")).toMatch(/Tue(sday)?,? Sep 15/);
  });
});

describe("the Availability view's copy", () => {
  it("says what it searches — the next 7 days from today — not 'next week'", async () => {
    const host = await mount();
    await act(async () => button(host, "Availability")!.click());
    const text = host.querySelector(".avail")?.textContent ?? "";
    expect(text).not.toContain("next week");
    expect(text).toContain("next 7 days");
  });
});
