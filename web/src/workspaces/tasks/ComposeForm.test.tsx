/*
 * The focus-block compose form: what it opens on is what it commits.
 *
 * A drop lands on a gap's own start (10:20 after a lecture that ends at 10:20),
 * and the keyboard path lands on the first free gap. Either way the Starts
 * control must be SHOWING that time — a controlled <select> whose value has no
 * matching option renders the first option instead, so the form claimed 09:00
 * while the preview said 10:20, and one touch of the control jumped the block to
 * a time nobody chose.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { TimeBlockDrag, type ComposeTarget } from "./TimeBlockDrag";

let roots: Root[] = [];
afterEach(() => {
  act(() => roots.forEach((r) => r.unmount()));
  roots = [];
  document.body.innerHTML = "";
});

function target(startMin: number, durationMin = 40): ComposeTarget {
  return {
    taskId: "t9",
    taskTitle: "Reconcile September budget",
    category: "finance",
    listName: "Finance",
    startMin,
    durationMin,
  };
}

async function mountCompose(compose: ComposeTarget, extra: Partial<Parameters<typeof TimeBlockDrag>[0]> = {}) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const onCommit = vi.fn();
  const onCancel = vi.fn();
  const root = createRoot(host);
  roots.push(root);
  await act(async () => {
    root.render(
      createElement(TimeBlockDrag, {
        schedule: [],
        blocks: [],
        compose,
        calendars: ["Finance"],
        windowStart: 9 * 60,
        windowEnd: 21 * 60,
        onDropStart: vi.fn(),
        onCommit,
        onCancel,
        onResolve: vi.fn(),
        onRemove: vi.fn(),
        ...extra,
      }),
    );
  });
  const starts = host.querySelector("form.compose select") as HTMLSelectElement;
  return { host, starts, onCommit, onCancel };
}

describe("the compose form's Starts control", () => {
  it("shows the exact dropped time when it is off the round steps", async () => {
    const { starts } = await mountCompose(target(10 * 60 + 20));
    expect(starts.value).toBe(String(10 * 60 + 20));
    expect(starts.selectedOptions[0]?.textContent).toBe("10:20");
  });

  it("shows a 5-minute-granular drop (14:15 after a coffee chat) too", async () => {
    const { starts } = await mountCompose(target(14 * 60 + 15));
    expect(starts.selectedOptions[0]?.textContent).toBe("14:15");
  });

  it("commits the dropped start unchanged when nothing is touched", async () => {
    const { host, onCommit } = await mountCompose(target(10 * 60 + 20));
    await act(async () => {
      (host.querySelector("form.compose") as HTMLFormElement).requestSubmit();
    });
    expect(onCommit).toHaveBeenCalledWith(10 * 60 + 20, 40, "Finance");
  });
});

describe("the compose form names a conflict before it is proposed", () => {
  const at = (m: number) =>
    `2026-09-21T${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}:00-07:00`;
  const focus = {
    id: "f",
    calendarId: "primary",
    title: "Focus — Assignment 3",
    category: "school",
    kind: "deadline",
    start: at(11 * 60),
    end: at(12 * 60),
    due: null,
    location: null,
  } as const;

  it("warns when the chosen time sits on an existing block", async () => {
    const { host } = await mountCompose(target(11 * 60, 60), { schedule: [focus] });
    expect(host.querySelector(".compose__warn")?.textContent).toContain("Overlaps Focus — Assignment 3");
  });

  it("says nothing when the time is free", async () => {
    const { host } = await mountCompose(target(12 * 60, 60), { schedule: [focus] });
    expect(host.querySelector(".compose__warn")).toBeNull();
  });
});
