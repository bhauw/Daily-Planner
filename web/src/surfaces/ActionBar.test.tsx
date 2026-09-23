/*
 * The keys beside a row's buttons are live, scoped, and harmless.
 *
 * Every card on Today printed "R" and "O" beside Reply and Find in Gmail, and pressing either
 * did nothing. These press them: each hint must reach the same thing its button does, only on
 * the card that holds focus, never from inside a field, and never as far as sending.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type {
  Capability,
  CreateEventRequest,
  CreateEventResponse,
  Draft,
  DraftReplyRequest,
  DraftReplyResponse,
  MoveEventRequest,
  PlannerEvent,
  SendMailRequest,
  SendMailResponse,
  TaskItem,
} from "../api/client";
import { DraftCard } from "../components/DraftCard";
import { WriteDeskProvider } from "../compose/WriteDesk";
import { ActionBar } from "./ActionBar";
import { eventActions, taskActions } from "./actions";

const CAN: Capability = { canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false };

const sendMail = vi.fn(async (_r: SendMailRequest): Promise<SendMailResponse> => {
  throw new Error("a key must never send");
});
const client = {
  sendMail,
  createEvent: async (_r: CreateEventRequest): Promise<CreateEventResponse> => {
    throw new Error("a key must never write");
  },
  moveEvent: async (_r: MoveEventRequest): Promise<CreateEventResponse> => {
    throw new Error("a key must never write");
  },
  draftReply: async (_r: DraftReplyRequest): Promise<DraftReplyResponse> => {
    throw new Error("not used");
  },
};

const draftA: Draft = { id: "a", title: "Interview time", summary: "Thursday?", kind: "reply", sender: "recruiter@example.test", receivedAt: null };
const draftB: Draft = { id: "b", title: "Lease bonuses", summary: "Checked your record", kind: "reply", sender: "leasing@example.test", receivedAt: null };

const event: PlannerEvent = {
  id: "e1",
  calendarId: "primary",
  title: "ECONOMICS 295",
  category: "school",
  kind: "event",
  start: "2026-09-16T11:00:00-07:00",
  end: "2026-09-16T12:30:00-07:00",
  due: null,
  location: null,
};
const task: TaskItem = { id: "t1", title: "Quiz", category: "school", due: null, done: false };

let host: HTMLElement;
let root: Root;

async function render(children: ReturnType<typeof createElement>) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root.render(createElement(WriteDeskProvider, { capability: CAN, client, assist: undefined, children }));
  });
}

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  sendMail.mockClear();
  vi.restoreAllMocks();
});

/** Presses a key where focus is — keydown goes to the focused element and bubbles. */
async function press(key: string, init: KeyboardEventInit = {}) {
  const target = (document.activeElement as HTMLElement | null) ?? document.body;
  await act(async () => {
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

function card(title: string): HTMLElement {
  return host.querySelector<HTMLElement>(`[aria-label="Draft: ${title}"]`)!;
}

const dialog = () => host.querySelector<HTMLElement>('[role="dialog"]');

describe("row keys", () => {
  it("R on a focused card opens the composer for that message, and sends nothing", async () => {
    await render(createElement(DraftCard, { draft: draftA }));
    card(draftA.title).focus();

    await press("r");

    expect(dialog()?.getAttribute("aria-label")).toBe("New message");
    expect(host.querySelector<HTMLInputElement>('input[value="Re: Interview time"]')).not.toBeNull();
    expect(sendMail).not.toHaveBeenCalled();
  });

  it("O opens the same Gmail search the Find in Gmail button does", async () => {
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    await render(createElement(DraftCard, { draft: draftA }));
    card(draftA.title).focus();

    await press("o");

    expect(open).toHaveBeenCalledWith(
      "https://mail.google.com/mail/u/0/#search/Interview%20time",
      "_blank",
      "noopener,noreferrer",
    );
  });

  it("S on an event or a task row opens the scheduler, and writes nothing", async () => {
    for (const [actions, subject, label] of [
      [eventActions(event, CAN), event.title, "Move event"],
      [taskActions(task, CAN), task.title, "New event"],
    ] as const) {
      await render(
        createElement("article", { "data-keyscope": true, tabIndex: -1, id: "row" }, createElement(ActionBar, { actions, subject })),
      );
      host.querySelector<HTMLElement>("#row")!.focus();
      await press("s");
      expect(dialog()?.getAttribute("aria-label")).toBe(label);
      act(() => root.unmount());
      host.remove();
      await render(createElement("div"));
    }
  });

  it("acts only on the card that holds focus, not on every card showing the hint", async () => {
    await render(
      createElement("div", null, createElement(DraftCard, { draft: draftA }), createElement(DraftCard, { draft: draftB })),
    );
    // Focus on a button inside the second card, as after tabbing to it.
    card(draftB.title).querySelector("button")!.focus();

    await press("r");

    expect(host.querySelectorAll('[role="dialog"]')).toHaveLength(1);
    expect(host.querySelector<HTMLInputElement>('input[value="Re: Lease bonuses"]')).not.toBeNull();
  });

  it("does nothing when focus is not on any card", async () => {
    await render(createElement(DraftCard, { draft: draftA }));
    (document.activeElement as HTMLElement | null)?.blur();

    await press("r");

    expect(dialog()).toBeNull();
  });

  it("does not fire while typing in a field inside the card", async () => {
    await render(
      createElement(
        "article",
        { "data-keyscope": true, tabIndex: -1 },
        createElement("input", { id: "note" }),
        createElement(ActionBar, { actions: taskActions(task, CAN), subject: task.title }),
      ),
    );
    host.querySelector<HTMLInputElement>("#note")!.focus();

    await press("s");

    expect(dialog()).toBeNull();
  });

  it("leaves ⌘-combinations alone, so ⌘R still reloads", async () => {
    await render(createElement(DraftCard, { draft: draftA }));
    card(draftA.title).focus();

    await press("r", { metaKey: true });

    expect(dialog()).toBeNull();
  });

  it("ignores the keys of a row that is folded shut", async () => {
    await render(
      createElement(
        "details",
        { "data-keyscope": true, tabIndex: -1, id: "row" },
        createElement("summary", null, "ECONOMICS 295"),
        createElement(ActionBar, { actions: eventActions(event, CAN), subject: event.title }),
      ),
    );
    host.querySelector<HTMLElement>("#row")!.focus();

    await press("s");
    expect(dialog()).toBeNull();

    // Opened, the same key works: the hint is visible again, so the key is live again.
    host.querySelector<HTMLDetailsElement>("#row")!.open = true;
    await press("s");
    expect(dialog()).not.toBeNull();
  });

  it("announces each live key on its button", async () => {
    await render(createElement(DraftCard, { draft: draftA }));
    const reply = Array.from(host.querySelectorAll("button")).find((b) => b.textContent?.trim() === "Reply")!;
    expect(reply.getAttribute("aria-keyshortcuts")).toBe("R");
  });
});
