/*
 * "Block time" made real (P4). Pinned: with a calendar grant, approving a proposed focus block
 * opens the scheduler prefilled with that block — and nothing is written until the scheduler's
 * own button; without a grant, approval stays local and says so.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Capability, CreateEventRequest } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { TimeBlockDrag } from "./TimeBlockDrag";
import type { BlockProposal } from "./machine";

const CAN: Capability = { canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false };

const block: BlockProposal = {
  id: "block-1",
  status: "pending",
  kind: "block",
  taskId: "t1",
  taskTitle: "Essay",
  category: "school",
  day: "2026-09-14",
  startMin: 13 * 60,
  durationMin: 60,
  calendar: "School",
};

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
});

async function mount(capability: Capability) {
  const createEvent = vi.fn(async (r: CreateEventRequest) => ({ ok: true, id: "e1", start: r.start, end: r.end, htmlLink: null }));
  const onResolve = vi.fn();
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(
      createElement(WriteDeskProvider, {
        capability,
        client: { sendMail: vi.fn(), createEvent, moveEvent: vi.fn(), draftReply: vi.fn() } as never,
        children: createElement(TimeBlockDrag, {
          schedule: [],
          blocks: [block],
          compose: null,
          calendars: ["School"],
          windowStart: 9 * 60,
          windowEnd: 21 * 60,
          onDropStart: vi.fn(),
          onCommit: vi.fn(),
          onCancel: vi.fn(),
          onResolve,
          onRemove: vi.fn(),
        }),
      }),
    );
  });
  return { createEvent, onResolve };
}

const button = (text: string) => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text);

describe("Block time → calendar", () => {
  it("opens the scheduler prefilled with the block, and writes only on its confirm", async () => {
    const { createEvent, onResolve } = await mount(CAN);
    await act(async () => button("Add to calendar…")!.click());
    expect(createEvent).not.toHaveBeenCalled();
    expect(onResolve).not.toHaveBeenCalled();
    const title = document.querySelector<HTMLInputElement>(".compose__panel .compose__field input");
    expect(title?.value).toBe("Focus — Essay");

    await act(async () => button("Add to calendar")!.click());
    expect(createEvent).toHaveBeenCalledTimes(1);
    const [req] = createEvent.mock.calls[0];
    expect(new Date(req.start).toISOString()).toBe("2026-09-14T20:00:00.000Z"); // 13:00 PDT
    expect(new Date(req.end).toISOString()).toBe("2026-09-14T21:00:00.000Z");
    expect(req).not.toHaveProperty("calendarId");
  });

  it("keeps approval local, and says so, without a calendar grant", async () => {
    const { onResolve } = await mount({ ...CAN, canSchedule: false });
    expect(button("Add to calendar…")).toBeUndefined();
    expect(document.body.textContent).toContain("can’t write to Calendar");
    await act(async () => button("Approve")!.click());
    expect(onResolve).toHaveBeenCalledWith("block-1", "approved");
  });
});
