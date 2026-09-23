/*
 * Home never rendered an <h1> — its outermost heading was ColumnHeader's <h3> ("Up next"), so
 * the outline skipped straight from nothing to h3 to a nested h4 (axe page-has-heading-one;
 * audit finding #6). A real page <h1> now sits above the three panes (sr-only: Home has no
 * room for a fourth visible title next to Priority/Today/Assistant's own eyebrows), and
 * ColumnHeader's title is promoted to <h2> so the outline never skips a level.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import type { Draft, Preview, TasksResponse } from "../api/client";
import { ThreeColumn } from "./ThreeColumn";

const preview: Preview = { day: "2026-09-16", queue: [], schedule: [] };
const tasks: TasksResponse = { lists: [] } as unknown as TasksResponse;
const drafts: Draft[] = [];

async function render() {
  const host = document.createElement("div");
  const root = createRoot(host);
  await act(async () => {
    root.render(createElement(ThreeColumn, { preview, drafts, tasks, now: new Date("2026-09-16T09:00:00-07:00") }));
  });
  return { host, done: () => act(() => root.unmount()) };
}

describe("Home has a real page heading", () => {
  it("renders exactly one <h1>", async () => {
    const r = await render();
    expect(r.host.querySelectorAll("h1").length).toBe(1);
    r.done();
  });

  it("promotes the column headers so the outline goes h1 -> h2, not h1 -> h3", async () => {
    const r = await render();
    expect(r.host.querySelector("h3")).toBeNull();
    const colheads = r.host.querySelectorAll(".colhead__title");
    expect(colheads.length).toBeGreaterThan(0);
    for (const heading of colheads) expect(heading.tagName).toBe("H2");
    r.done();
  });
});
