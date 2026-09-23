/*
 * Digest wording that was wrong on screen: "4 unreads", and "Waiting on: Your reply" under a
 * bank statement and a no-reply security alert.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import type { Draft, Preview, TasksResponse } from "../api/client";
import { Digest } from "./Digest";

const preview: Preview = { queue: [], schedule: [], day: "2026-09-14" };
const tasks: TasksResponse = { lists: [] } as unknown as TasksResponse;
const drafts: Draft[] = [
  { id: "u1", title: "Security alert", summary: "", kind: "reply", sender: "no-reply@accounts.example.com", band: "urgent", reason: "security", unread: true },
  { id: "d5", title: "Your statement is ready", summary: "", kind: "reply", sender: "alerts@example-bank.com", category: "finance", band: "ordinary", reason: "category", unread: true },
  { id: "d1", title: "Reply — recruiter", summary: "", kind: "reply", sender: "recruiter@example.com", category: "career", band: "ordinary", reason: "category", unread: false },
];

async function render() {
  const host = document.createElement("div");
  const root = createRoot(host);
  await act(async () => {
    root.render(createElement(Digest, { preview, tasks, drafts, now: new Date("2026-09-14T09:30:00-07:00") }));
  });
  return { host, done: () => act(() => root.unmount()) };
}

describe("Digest wording", () => {
  it("does not pluralise unread into 'unreads'", async () => {
    const r = await render();
    const summary = r.host.querySelector(".digest__summary")!.textContent!;
    expect(summary).toContain("2 unread");
    expect(summary).not.toContain("unreads");
    r.done();
  });

  it("says Waiting on only for mail that is waiting on a reply", async () => {
    const r = await render();
    const rows = Array.from(r.host.querySelectorAll("details.drow"));
    const waiting = (title: string) =>
      rows.find((d) => d.textContent?.includes(title))!.textContent!.includes("Waiting on");
    expect(waiting("Security alert")).toBe(false);
    expect(waiting("Your statement is ready")).toBe(false);
    expect(waiting("Reply — recruiter")).toBe(true);
    r.done();
  });
});
