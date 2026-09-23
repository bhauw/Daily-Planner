/*
 * `role="listitem"` on a <details> is not an ARIA role that element accepts — the conflicting
 * native disclosure semantics make it invalid, and a screen reader may not announce these rows
 * as list items at all (audit finding #5). The grouped remainder is a real <ul>/<li> instead,
 * with <details> kept for its native disclosure behaviour inside each <li>.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import type { Draft, PlannerEvent, Preview, TasksResponse } from "../api/client";
import { Focus } from "./Focus";

const NOW = new Date("2026-09-16T12:00:00-07:00");
const at = (offsetMinutes: number) => new Date(NOW.getTime() + offsetMinutes * 60_000).toISOString();

function event(over: Partial<PlannerEvent> & Pick<PlannerEvent, "id" | "title">): PlannerEvent {
  return {
    calendarId: "primary",
    category: "school",
    kind: "event",
    start: at(0),
    end: null,
    due: null,
    location: null,
    ...over,
  };
}

// Two events far enough apart that one leads and at least two others land in the grouped
// remainder — the case that exercises the list markup.
const preview: Preview = {
  day: "2026-09-16",
  queue: [],
  schedule: [
    event({ id: "e1", title: "Running now", start: at(-10), end: at(20) }),
    event({ id: "e2", title: "Later today", start: at(180) }),
    event({ id: "e3", title: "Also later", start: at(240) }),
  ],
};
const tasks: TasksResponse = { lists: [] } as unknown as TasksResponse;
const drafts: Draft[] = [];

async function render() {
  const host = document.createElement("div");
  const root = createRoot(host);
  await act(async () => {
    root.render(createElement(Focus, { preview, tasks, drafts, now: NOW }));
  });
  return { host, done: () => act(() => root.unmount()) };
}

describe("Focus row list markup", () => {
  it("groups rows under a real <ul>, never role=list on a <div>", async () => {
    const r = await render();
    const lists = r.host.querySelectorAll("ul");
    expect(lists.length).toBeGreaterThan(0);
    expect(r.host.querySelector('[role="list"]')).toBeNull();
    r.done();
  });

  it("never puts role=listitem on a <details>", async () => {
    const r = await render();
    const rows = r.host.querySelectorAll("details.focus__row");
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) expect(row.getAttribute("role")).toBeNull();
    r.done();
  });

  it("wraps every row's <details> in a real <li>", async () => {
    const r = await render();
    const rows = r.host.querySelectorAll("details.focus__row");
    for (const row of rows) expect(row.parentElement?.tagName).toBe("LI");
    r.done();
  });
});
