/*
 * The drag surface: dropping a task BETWEEN two blocks.
 *
 * jsdom has no layout, so every getBoundingClientRect is 0x0 — which would make
 * "the gap nearest the pointer" trivially true for the first gap and prove
 * nothing. These tests give the wrapper and the rendered block rows real
 * geometry, so the row measurement the drag depends on is actually exercised: a
 * pointer near the lower row must pick the gap above THAT row, not the first one.
 */

// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import type { PlannerEvent } from "../contract";
import { TimeBlockDrag } from "./TimeBlockDrag";

const DAY = "2026-09-21";
const WINDOW_START = 9 * 60;
const WINDOW_END = 21 * 60;

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

// 09:00 [gap] · a 10:00–11:00 · [gap 11:00–14:00] · b 14:00–15:00 · [gap] 21:00
const SCHEDULE = [ev("a", 10 * 60, 11 * 60), ev("b", 14 * 60, 15 * 60)];

function rectOf(top: number, bottom: number) {
  return () =>
    ({
      top,
      bottom,
      height: bottom - top,
      left: 0,
      right: 0,
      width: 0,
      x: 0,
      y: top,
      toJSON: () => ({}),
    }) as DOMRect;
}

interface Mounted {
  wrap: HTMLElement;
  cue: () => HTMLElement | null;
  status: () => string;
  dragOver: (clientY: number) => Promise<void>;
  drop: (clientY: number) => Promise<void>;
  dragLeave: () => Promise<void>;
  onDropStart: ReturnType<typeof vi.fn>;
}

/**
 * Mount with a layout: the wrapper spans y 0–400, row "a" sits at 100–200 and
 * row "b" at 300–400. So the gap before "a" anchors at 100, the gap between the
 * two at 300, and the trailing gap at 400.
 */
async function mount(): Promise<Mounted> {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const onDropStart = vi.fn();

  await act(async () => {
    createRoot(host).render(
      createElement(TimeBlockDrag, {
        schedule: SCHEDULE,
        blocks: [],
        compose: null,
        calendars: ["School"],
        windowStart: WINDOW_START,
        windowEnd: WINDOW_END,
        onDropStart,
        onCommit: vi.fn(),
        onCancel: vi.fn(),
        onResolve: vi.fn(),
        onRemove: vi.fn(),
      }),
    );
  });

  const wrap = host.querySelector(".timeblock__dayline") as HTMLElement;
  wrap.getBoundingClientRect = rectOf(0, 400);
  (host.querySelector('[data-event-id="a"]') as HTMLElement).getBoundingClientRect = rectOf(100, 200);
  (host.querySelector('[data-event-id="b"]') as HTMLElement).getBoundingClientRect = rectOf(300, 400);

  // jsdom has no DragEvent; a MouseEvent carries clientY and the same interface
  // React reads for dropEffect, which is all these handlers touch.
  const fire = async (type: string, init: MouseEventInit & { relatedTarget?: EventTarget }) => {
    await act(async () => {
      const e = new MouseEvent(type, { bubbles: true, cancelable: true, ...init });
      Object.defineProperty(e, "dataTransfer", { value: { dropEffect: "none" } });
      if (init.relatedTarget) Object.defineProperty(e, "relatedTarget", { value: init.relatedTarget });
      wrap.dispatchEvent(e);
    });
  };

  return {
    wrap,
    onDropStart,
    cue: () => host.querySelector('[data-testid="insert-cue"]'),
    status: () => host.querySelector('[role="status"]')?.textContent ?? "",
    dragOver: (clientY) => fire("dragover", { clientY }),
    drop: (clientY) => fire("drop", { clientY }),
    dragLeave: () => fire("dragleave", { relatedTarget: document.body }),
  };
}

describe("dropping a task between two blocks", () => {
  it("shows no insertion cue until something is dragged over", async () => {
    const m = await mount();
    expect(m.cue()).toBeNull();
  });

  it("names the two blocks' gap while dragging over the space between them", async () => {
    const m = await mount();
    await m.dragOver(290);
    expect(m.cue()?.textContent).toContain("Between these · 11:00–12:00");
  });

  it("draws the cue AT the boundary between the rows, not over the whole surface", async () => {
    const m = await mount();
    await m.dragOver(290);
    // Row "b" starts at y=300; the line is the top of the block it will precede.
    expect((m.cue() as HTMLElement).style.top).toBe("300px");
  });

  it("picks the gap ABOVE the first block when the pointer is up there", async () => {
    const m = await mount();
    await m.dragOver(90);
    expect(m.cue()?.textContent).toContain("Before the first block · 09:00–10:00");
    expect((m.cue() as HTMLElement).style.top).toBe("100px");
  });

  it("picks the trailing gap when the pointer is below the last block", async () => {
    const m = await mount();
    await m.dragOver(398);
    expect(m.cue()?.textContent).toContain("After the last block · 15:00–16:00");
  });

  it("commits the GAP's time, not the time under the cursor", async () => {
    const m = await mount();
    await m.dragOver(290);
    await m.drop(290);
    expect(m.onDropStart).toHaveBeenCalledWith(11 * 60, 60);
  });

  it("clears the cue once the pointer leaves the surface", async () => {
    const m = await mount();
    await m.dragOver(290);
    await m.dragLeave();
    expect(m.cue()).toBeNull();
  });

  it("announces the slot, since the line itself is decorative", async () => {
    const m = await mount();
    await m.dragOver(290);
    expect(m.status()).toContain("Between these · 11:00–12:00");
  });
});
