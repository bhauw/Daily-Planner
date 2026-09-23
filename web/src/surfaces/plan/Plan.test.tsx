/*
 * Plan my day, driven the way he uses it. Pinned: nothing is written through steps 1–3; the
 * confirm writes exactly one event per listed row; a partial failure is reported per row with an
 * explicit retry; a read-only grant is explained and offered no confirm; an over-committed day
 * shows what does not fit; and the shell reloads once, after he leaves.
 */

// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ApiError, type Capability, type CreateEventRequest, type Draft, type Preview, type TasksResponse } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { Plan, resetPlanSession } from "./Plan";

const DAY = "2026-09-14";
const at = (hhmm: string) => `${DAY}T${hhmm}:00-07:00`;
// A different day from the plan's, so the whole working window is free to plan.
const NOW = new Date("2026-09-13T08:00:00-07:00");

const CAN: Capability = { canSend: true, canSchedule: true, canReschedule: true, canDraft: true, canReadBody: true, canSummarize: true };
const READ_ONLY: Capability = { ...CAN, canSend: false, canSchedule: false, canReschedule: false };

const preview: Preview = {
  day: DAY,
  queue: [],
  schedule: [
    { id: "lec", title: "Lecture", category: "school", kind: "event", start: at("09:00"), end: at("17:00"), due: null, location: null, calendarId: "primary" },
  ],
};

const tasks: TasksResponse = {
  lists: [
    { name: "School", items: [
      { id: "t1", title: "Essay", category: "school", due: null, done: false },
      { id: "t2", title: "Problem set", category: "school", due: null, done: false },
      { id: "t3", title: "Readings", category: "school", due: null, done: false },
    ] },
  ],
};

const drafts: Draft[] = [
  { id: "u1", title: "Interview confirmed", summary: "See you then.", kind: "reply", sender: "r@example.com", category: "career", band: "urgent", reason: "interview", why: "Interview" },
];

let root: Root | null = null;
let host: HTMLElement | null = null;

beforeEach(() => resetPlanSession());
afterEach(() => {
  act(() => root?.unmount());
  root = null;
  host?.remove();
});

function setup({ capability = CAN, create = vi.fn(async (r: CreateEventRequest) => ({ ok: true, id: `id-${r.title}`, start: r.start, end: r.end, htmlLink: null })) } = {}) {
  const onWrote = vi.fn();
  const onDone = vi.fn();
  const summarizeMail = vi.fn(async () => ({ ok: true, summary: "Short.", provider: "Test" }));
  const deskClient = { sendMail: vi.fn(), createEvent: vi.fn(), moveEvent: vi.fn(), draftReply: vi.fn() } as never;
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => {
    root!.render(
      createElement(WriteDeskProvider, {
        capability,
        client: deskClient,
        children: createElement(Plan, {
          preview,
          tasks,
          drafts,
          capability,
          onWrote,
          onDone,
          now: NOW,
          client: { createEvent: create, summarizeMail },
        }),
      }),
    );
  });
  return { create, onWrote, onDone, summarizeMail };
}

const button = (name: string | RegExp) =>
  [...host!.querySelectorAll("button")].find((b) =>
    typeof name === "string" ? b.textContent?.trim() === name : name.test(b.textContent ?? ""),
  );

async function press(name: string | RegExp) {
  const b = button(name);
  if (!b) throw new Error(`no button ${name}`);
  await act(async () => b.click());
}

async function tick(title: string) {
  const row = [...host!.querySelectorAll(".pickrow")].find((r) => r.textContent?.includes(title))!;
  await act(async () => row.querySelector<HTMLInputElement>("input[type=checkbox]")!.click());
}

async function sizeOf(title: string, label: string) {
  const row = [...host!.querySelectorAll(".pickrow, .fitrow")].find((r) => r.textContent?.includes(title))!;
  const chip = [...row.querySelectorAll("button")].find((b) => b.textContent === label)!;
  await act(async () => chip.click());
}

describe("Plan my day", () => {
  it("writes nothing through steps 1–3, then exactly one event per listed row on confirm", async () => {
    const { create } = setup();
    expect(host!.textContent).toContain("Interview confirmed");
    await press("Pick today’s work");
    await tick("Essay");
    await tick("Problem set");
    await sizeOf("Problem set", "30m");
    expect(host!.textContent).toContain("1h 30m planned / 4h free");
    await press("See how it fits");
    expect(host!.textContent).toContain("17:00–18:00");
    expect(host!.textContent).toContain("18:00–18:30");
    await press("Review the blocks");
    expect(create).not.toHaveBeenCalled();

    const rows = [...host!.querySelectorAll(".reviewrow")].map((r) => r.textContent);
    expect(rows).toHaveLength(2);
    await press("Add 2 focus blocks");
    expect(create).toHaveBeenCalledTimes(2);
    expect(create.mock.calls.map(([r]) => r.title)).toEqual(["Focus — Essay", "Focus — Problem set"]);
    expect(host!.textContent).toContain("All 2 added to your calendar.");
    // The confirm is gone: it cannot be pressed twice.
    expect(button(/^Add \d focus/)).toBeUndefined();
  });

  it("moves focus to the new step's heading", async () => {
    setup();
    await press("Pick today’s work");
    expect(document.activeElement?.id).toBe("plan-step-title");
    expect(document.activeElement?.textContent).toBe("What gets time today?");
  });

  it("reports a partial failure per row and retries only on an explicit press", async () => {
    let calls = 0;
    const create = vi.fn(async (r: CreateEventRequest) => {
      calls += 1;
      if (calls === 2) throw new ApiError("provider_refused", "Google would not accept that.");
      return { ok: true, id: `id-${calls}`, start: r.start, end: r.end, htmlLink: null };
    });
    setup({ create });
    await press("Pick today’s work");
    await tick("Essay");
    await tick("Problem set");
    await tick("Readings");
    await press("See how it fits");
    await press("Review the blocks");
    await press("Add 3 focus blocks");

    expect(create).toHaveBeenCalledTimes(3);
    expect(host!.textContent).toContain("2 of 3 added. 1 not added — each is marked below.");
    const states = [...host!.querySelectorAll(".reviewrow__state")].map((s) => s.textContent);
    expect(states).toEqual(["Added", "Not added", "Added"]);
    expect(host!.textContent).toContain("Google would not accept that.");

    await press("Try again");
    expect(create).toHaveBeenCalledTimes(4);
    expect([...host!.querySelectorAll(".reviewrow__state")].map((s) => s.textContent)).toEqual(["Added", "Added", "Added"]);
  });

  it("explains a read-only grant and offers a copy, never a confirm", async () => {
    const { create } = setup({ capability: READ_ONLY });
    await press("Pick today’s work");
    await tick("Essay");
    await press("See how it fits");
    await press("Review the blocks");
    expect(host!.textContent).toContain("connected for reading only");
    expect(button(/^Add \d focus/)).toBeUndefined();
    expect(button("Copy plan")).toBeDefined();
    expect(create).not.toHaveBeenCalled();
  });

  it("shows what does not fit on an over-committed day, and leaves it out of the write", async () => {
    const { create } = setup();
    await press("Pick today’s work");
    for (const t of ["Essay", "Problem set", "Readings"]) {
      await tick(t);
      await sizeOf(t, "1h 30m");
    }
    expect(host!.querySelector(".fitmeter--over")).not.toBeNull();
    expect(host!.textContent).toContain("over by 30m");
    await press("See how it fits");
    expect(host!.textContent).toContain("1 block doesn’t fit.");
    expect(host!.querySelector(".fitrow.is-over")?.textContent).toContain("Readings");

    // Shrinking the one that overflowed makes it fit.
    await sizeOf("Readings", "1h");
    expect(host!.querySelector(".fitrow.is-over")).toBeNull();
    await sizeOf("Readings", "1h 30m");

    await press("Review the blocks");
    await press("Add 2 focus blocks");
    expect(create).toHaveBeenCalledTimes(2);
  });

  it("reloads the shell once, when he is done, and only if something was written", async () => {
    const { onWrote, onDone } = setup();
    await press("Pick today’s work");
    await tick("Essay");
    await press("See how it fits");
    await press("Review the blocks");
    await press("Add 1 focus block");
    // Not yet: reloading would unmount the outcome he still has to read.
    expect(onWrote).not.toHaveBeenCalled();
    await press("Done — back to Today");
    expect(onWrote).toHaveBeenCalledTimes(1);
    expect(onDone).toHaveBeenCalledTimes(1);
    act(() => root!.unmount());
    root = null;
    expect(onWrote).toHaveBeenCalledTimes(1);
  });

  it("puts a must-read off for the session with Later", async () => {
    setup();
    await press(/^Later/);
    expect(host!.textContent).toContain("Nothing to read first");
  });
});
