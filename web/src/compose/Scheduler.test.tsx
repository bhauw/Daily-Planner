/*
 * "Move it" must say what a new time sits on BEFORE it is pressed.
 *
 * It validated only the name and the start/end order, so moving the 11:00 focus
 * block to 09:30 — straight onto a ECONOMICS 250 lecture — ended on a green "✓ Moved"
 * with not a word about the lecture. The move is still allowed (the student
 * may mean it); what is not allowed is doing it silently.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { PlannerEvent } from "../api/client";
import { Scheduler } from "./Scheduler";

const at = (hm: string) => `2026-09-14T${hm}:00-07:00`;

function ev(id: string, title: string, s: string, e: string, location: string | null = null): PlannerEvent {
  return { id, calendarId: "c1", title, category: "school", kind: "event", start: at(s), end: at(e), due: null, location } as PlannerEvent;
}

const lecture = ev("lec", "ECONOMICS 250 Lecture", "09:00", "10:20", "AQ 3150");
const focus = { ...ev("focus", "Focus — Assignment 3", "11:00", "12:00"), kind: "deadline" } as PlannerEvent;

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
  const move = vi.fn(async () => ({ ok: true, id: "focus", start: at("09:30"), end: at("10:30"), htmlLink: null }));
  await act(async () => {
    root.render(
      createElement(Scheduler, {
        prefill: {
          title: focus.title,
          start: focus.start,
          end: focus.end!,
          move: { eventId: "focus", calendarId: "c1" },
          busy: [lecture, focus],
        },
        create: vi.fn(),
        move,
        onClose: vi.fn(),
      }),
    );
  });
  const starts = host.querySelectorAll('input[type="datetime-local"]')[0] as HTMLInputElement;
  const setStart = async (value: string) => {
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(starts, value);
      starts.dispatchEvent(new Event("input", { bubbles: true }));
    });
  };
  return { host, move, setStart };
}

describe("Move it checks the new time against the day", () => {
  it("names nothing at the event's own time — it does not collide with itself", async () => {
    const { host } = await mount();
    expect(host.querySelector(".compose__conflict")).toBeNull();
  });

  it("warns, naming the lecture and its buffer, when the new start overlaps it", async () => {
    const { host, setStart } = await mount();
    await setStart("2026-09-14T09:30");
    const warn = host.querySelector(".compose__conflict");
    expect(warn?.textContent).toContain("Overlaps ECONOMICS 250 Lecture");
    expect(warn?.textContent).toContain("30 min buffer");
    // The button says what pressing it means now.
    expect(host.querySelector('button[type="submit"]')?.textContent).toBe("Move anyway");
  });

  it("still reports the overlap after the move, instead of a clean 'Moved'", async () => {
    const { host, setStart, move } = await mount();
    await setStart("2026-09-14T09:30");
    await act(async () => {
      (host.querySelector("form") as HTMLFormElement).requestSubmit();
    });
    expect(move).toHaveBeenCalled();
    expect(host.querySelector(".compose__done")?.textContent).toContain("Overlaps ECONOMICS 250 Lecture");
  });
});
