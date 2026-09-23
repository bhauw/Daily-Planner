/*
 * The assistant column on Today shipped with eight buttons that did nothing.
 *
 * `DraftCard` rendered its own "Review" and "Edit" with no `onClick` at all, so the first thing
 * anyone pressed on the app's default route — a primary-blue button, four of them down the
 * right-hand side — produced no busy state, no error and no navigation. Braxton hit exactly
 * this and reported "buttons like review and edit on today doesnt work".
 *
 * These tests pin the property that was missing: pressing the card's primary action reaches the
 * write desk. A card whose buttons are inert fails here.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type {
  CreateEventRequest,
  CreateEventResponse,
  Capability,
  Draft,
  DraftReplyRequest,
  DraftReplyResponse,
  MoveEventRequest,
  SendMailRequest,
  SendMailResponse,
} from "../api/client";
import { WriteDeskProvider } from "../compose/WriteDesk";
import { DraftCard } from "./DraftCard";

const client = {
  sendMail: async (_r: SendMailRequest): Promise<SendMailResponse> => {
    throw new Error("not used");
  },
  createEvent: async (_r: CreateEventRequest): Promise<CreateEventResponse> => {
    throw new Error("not used");
  },
  moveEvent: async (_r: MoveEventRequest): Promise<CreateEventResponse> => {
    throw new Error("not used");
  },
  draftReply: async (_r: DraftReplyRequest): Promise<DraftReplyResponse> => {
    throw new Error("not used");
  },
};

const draft: Draft = {
  id: "d1",
  title: "Example Corp Audit Co-op — interview time",
  summary: "Confirms Thursday 14:30.",
  kind: "reply",
  sender: "recruiter@example.test",
  category: "career",
  receivedAt: null,
  threadId: "thread-1",
};

interface Mounted {
  host: HTMLElement;
  root: Root;
  buttons: () => HTMLButtonElement[];
  press: (label: string) => Promise<void>;
  dialog: () => HTMLElement | null;
}

async function mount(capability: Capability, card: Draft = draft): Promise<Mounted> {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);

  await act(async () => {
    root.render(
      createElement(WriteDeskProvider, {
        capability,
        client,
        assist: undefined,
        children: createElement(DraftCard, { draft: card }),
      }),
    );
  });

  const buttons = () => Array.from(host.querySelectorAll("button")) as HTMLButtonElement[];

  return {
    host,
    root,
    buttons,
    dialog: () => host.querySelector<HTMLElement>('[role="dialog"]'),
    press: async (label: string) => {
      const target = buttons().find((b) => (b.textContent ?? "").trim() === label);
      if (!target) throw new Error(`no button labelled "${label}" — found: ${buttons().map((b) => b.textContent).join(", ")}`);
      await act(async () => {
        target.click();
      });
    },
  };
}

function cleanup(m: Mounted) {
  act(() => m.root.unmount());
  m.host.remove();
}

describe("DraftCard actions", () => {
  it("offers a working in-app Reply when the grant can send", async () => {
    const m = await mount({ canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false });

    expect(m.buttons().map((b) => b.textContent?.trim())).toContain("Reply");
    expect(m.dialog()).toBeNull();

    await m.press("Reply");

    // The composer is open — the button did something, which is the whole point.
    const dialog = m.dialog();
    expect(dialog).not.toBeNull();
    expect(dialog?.getAttribute("aria-label")).toBe("New message");

    cleanup(m);
  });

  it("never renders a button with no behaviour behind it", async () => {
    const m = await mount({ canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false });

    // Every button on the card must either open the desk, open a link, or copy. The old
    // "Review"/"Edit" pair satisfied none of those, and this is what catches their return.
    const labels = m.buttons().map((b) => b.textContent?.trim());
    expect(labels).not.toContain("Review");
    expect(labels).not.toContain("Edit");
    expect(labels.length).toBeGreaterThan(0);

    cleanup(m);
  });

  it("falls back to Gmail rather than an in-app composer when the grant cannot send", async () => {
    const m = await mount({ canSend: false, canSchedule: false, canReschedule: false, canDraft: false, canReadBody: false, canSummarize: false });

    const labels = m.buttons().map((b) => b.textContent?.trim());
    expect(labels).toContain("Reply in Gmail");
    expect(labels).not.toContain("Reply");

    cleanup(m);
  });

  /*
   * A "Calendar + Task bundle" has no sender and nothing to reply to, yet its primary button
   * was "Reply in Gmail" — the only thing the card could NOT be for. It now says what it is and,
   * until the engine hands over the bundle's items, why it cannot be reviewed here yet.
   */
  it("never offers a reply on a bundle, and says why it cannot be reviewed yet", async () => {
    const bundle: Draft = {
      id: "d2",
      title: "Calendar + Task bundle",
      summary: "Creates the Example Consulting chat, a prep task, and a 25-minute transit buffer.",
      kind: "bundle",
    };
    const m = await mount(
      { canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false },
      bundle,
    );

    const labels = m.buttons().map((b) => b.textContent?.trim());
    expect(labels.some((l) => /reply|gmail/i.test(l ?? ""))).toBe(false);
    const review = m.buttons().find((b) => b.textContent?.trim() === "Review bundle");
    expect(review).toBeDefined();
    expect(review!.disabled).toBe(true);
    expect(m.host.textContent).toMatch(/nothing has been created/i);
    expect(labels).toContain("Copy summary");

    cleanup(m);
  });
});
