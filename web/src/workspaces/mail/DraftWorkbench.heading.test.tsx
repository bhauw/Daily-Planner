/*
 * Mail never rendered an <h1> either — its outermost heading was ColumnHeader's <h3> ("Draft
 * workbench"). Same fix as Home and Tasks: a real page <h1> (sr-only — the eyebrow/title row
 * already carries the visible name), ColumnHeader promoted to <h2> (see Column.tsx).
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Api, Draft } from "../contract";
import { DraftWorkbench } from "./DraftWorkbench";

const draft: Draft = {
  id: "m1",
  title: "Coffee chat?",
  summary: "Free Thursday?",
  kind: "reply",
  sender: "sarah@example.com",
  category: "career",
  receivedAt: null,
  threadId: "t1",
} as Draft;

const fakeApi = {
  drafts: async () => ({ drafts: [draft] }),
  mailBody: async () => ({ id: "m1", text: "", truncated: false, attachments: [], unreadable: null }),
  week: async () => ({ start: "2026-09-16", days: 7, events: [] }),
  settings: async () => ({
    vaultSelected: true,
    scanTimes: [],
    safety: { mode: "read-only", externalWrites: false, label: "Read-only" },
    source: { kind: "google", live: true, label: "Live" },
    capability: {
      canSend: false,
      canSchedule: false,
      canReschedule: false,
      canDraft: false,
      canReadBody: false,
      canSummarize: false,
    },
  }),
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
    root.render(createElement(DraftWorkbench, { api: fakeApi, detached: false }));
  });
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
  return host;
}

describe("Mail has a real page heading", () => {
  it("renders exactly one <h1>", async () => {
    const host = await mount();
    expect(host.querySelectorAll("h1").length).toBe(1);
  });

  it("promotes the column headers so the outline goes h1 -> h2, not h1 -> h3", async () => {
    const host = await mount();
    expect(host.querySelector("h3")).toBeNull();
    const colheads = host.querySelectorAll(".colhead__title");
    expect(colheads.length).toBeGreaterThan(0);
    for (const heading of colheads) expect(heading.tagName).toBe("H2");
  });
});
