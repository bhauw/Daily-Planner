/*
 * The prep card's promises that a pure test cannot pin: nothing leaves the Mac when the card
 * opens, "Draft thank-you" only ever lands in the app's one composer — never sends by itself —
 * and a drafting failure still offers a way to write the note by hand. "Nothing sends without
 * confirm" is checked the same way ReviewAndSend.test.tsx checks it for the ordinary reply
 * path: drive the button, assert the composer opened, assert `sendMail` was never called.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

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
  SendMailRequest,
  SendMailResponse,
  SummarizeMailRequest,
  SummarizeMailResponse,
  TaskItem,
} from "../api/client";
import { WriteDeskProvider } from "../compose/WriteDesk";
import { detectPrep } from "./match";
import { PrepCard } from "./PrepCard";
import { resetPrepSession } from "./session";

const CAN: Capability = {
  canSend: true,
  canSchedule: true,
  canReschedule: true,
  canDraft: true,
  canReadBody: false,
  canSummarize: true,
};

const chatEvent = {
  id: "e1",
  title: "Example Consulting coffee chat",
  category: "career" as const,
  kind: "event" as const,
  start: "2026-09-21T13:00:00-07:00",
  end: "2026-09-21T13:45:00-07:00",
  due: null,
  location: "Example Cafe",
  calendarId: "primary",
};

const kpmgThread: Draft = {
  id: "k1",
  title: "Coffee chat Monday?",
  summary: "Great to connect at the Sauder mixer.",
  kind: "reply",
  sender: "jordan.lee@example.test",
  category: "career",
  receivedAt: null,
  threadId: "thread-k1",
  band: "ordinary",
};

const tasks: TaskItem[] = [];

interface Harness {
  host: HTMLElement;
  root: Root;
  sent: SendMailRequest[];
  drafted: DraftReplyRequest[];
  button: (label: string) => HTMLButtonElement | undefined;
  buttons: () => HTMLButtonElement[];
}

function unused(name: string) {
  return async () => {
    throw new Error(`${name} not used`);
  };
}

async function mount(opts: {
  now: Date;
  capability?: Capability;
  drafts?: Draft[];
  draftReply?: (r: DraftReplyRequest) => Promise<DraftReplyResponse>;
  summarizeMail?: (r: SummarizeMailRequest) => Promise<SummarizeMailResponse>;
}): Promise<Harness> {
  resetPrepSession();
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  const sent: SendMailRequest[] = [];
  const drafted: DraftReplyRequest[] = [];

  const writeDeskClient = {
    sendMail: async (r: SendMailRequest): Promise<SendMailResponse> => {
      sent.push(r);
      return { ok: true, id: "sent-1", threadId: r.threadId ?? null };
    },
    createEvent: unused("createEvent") as unknown as (r: CreateEventRequest) => Promise<CreateEventResponse>,
    moveEvent: unused("moveEvent") as unknown as (r: MoveEventRequest) => Promise<CreateEventResponse>,
    draftReply: async (r: DraftReplyRequest): Promise<DraftReplyResponse> => {
      drafted.push(r);
      if (opts.draftReply) return opts.draftReply(r);
      return { ok: true, body: "Thank you so much for the chat!", provider: "Claude" };
    },
  };

  const prepClient = {
    draftReply: writeDeskClient.draftReply,
    summarizeMail:
      opts.summarizeMail ??
      (async (): Promise<SummarizeMailResponse> => {
        throw new Error("summarizeMail not used");
      }),
  };

  const prep = detectPrep(chatEvent)!;

  await act(async () => {
    root.render(
      createElement(WriteDeskProvider, {
        capability: opts.capability ?? CAN,
        client: writeDeskClient,
        children: createElement(PrepCard, {
          prep,
          drafts: opts.drafts ?? [kpmgThread],
          tasks,
          now: opts.now,
          client: prepClient,
        }),
      }),
    );
  });

  const buttons = () => Array.from(host.querySelectorAll("button")) as HTMLButtonElement[];

  return {
    host,
    root,
    sent,
    drafted,
    buttons,
    button: (label: string) => buttons().find((b) => (b.textContent ?? "").trim() === label),
  };
}

function cleanup(h: Harness) {
  act(() => h.root.unmount());
  h.host.remove();
}

afterEach(() => {
  resetPrepSession();
});

describe("PrepCard — before the event", () => {
  it("shows the matched thread and its reason without sending anything", async () => {
    const h = await mount({ now: new Date("2026-09-21T10:00:00-07:00") }); // before start
    expect(h.host.textContent).toContain("Coffee chat Monday?");
    expect(h.host.textContent).toContain("jordan.lee@example.test");
    expect(h.sent).toEqual([]);
    expect(h.drafted).toEqual([]);
    cleanup(h);
  });

  it("says plainly when no thread was found, rather than guessing one", async () => {
    const h = await mount({ now: new Date("2026-09-21T10:00:00-07:00"), drafts: [] });
    expect(h.host.textContent).toContain("No thread found for Example Consulting");
    cleanup(h);
  });
});

describe("PrepCard — follow-through, 48h flip", () => {
  it("offers Draft thank-you once the chat has ended, and it only opens the composer", async () => {
    // 1h15m after the chat ends: inside the 48h window.
    const h = await mount({ now: new Date("2026-09-21T15:00:00-07:00") });
    expect(h.host.textContent).toContain("A thank-you within a day");

    const draftBtn = h.button("Draft thank-you")!;
    expect(draftBtn).toBeDefined();
    await act(async () => draftBtn.click());

    // The draft was requested by message id + instruction only — never by calendar detail —
    // and the result landed in the composer, not in an outbox.
    expect(h.drafted).toHaveLength(1);
    expect(h.drafted[0].messageId).toBe("k1");
    expect(h.sent).toEqual([]);

    const dialog = h.host.querySelector('[role="dialog"]') ?? document.querySelector('[role="dialog"]');
    expect(dialog).not.toBeNull();
    expect((dialog!.querySelector("textarea") as HTMLTextAreaElement).value).toContain("Thank you so much for the chat!");

    cleanup(h);
  });

  it("marks the thank-you sent only after the composer's own Send completes — not on open", async () => {
    const h = await mount({ now: new Date("2026-09-21T15:00:00-07:00") });
    await act(async () => h.button("Draft thank-you")!.click());

    // Opening the composer must not itself count as thanked.
    expect(h.host.textContent).not.toContain("Thank-you sent from here this session.");
    expect(h.sent).toEqual([]);

    // Drive the composer's own review step, exactly as ReviewAndSend.test.tsx does.
    const findButton = (label: string) =>
      [...document.querySelectorAll("button")].find((b) => (b.textContent ?? "").trim() === label) as
        | HTMLButtonElement
        | undefined;

    await act(async () => findButton("Review")!.click());
    expect(h.sent).toEqual([]); // still nothing — Review is not Send

    await act(async () => findButton("Send")!.click());
    // Flush the async send.
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(h.sent).toHaveLength(1);
    expect(h.sent[0].threadId).toBe("thread-k1");

    cleanup(h);
  });

  it("still opens a composer for a thank-you when drafting fails, rather than a dead end", async () => {
    const h = await mount({
      now: new Date("2026-09-21T15:00:00-07:00"),
      draftReply: async () => {
        throw new Error("boom");
      },
    });
    await act(async () => h.button("Draft thank-you")!.click());

    expect(h.host.textContent).toContain("Couldn't draft it");
    const writeItYourself = h.button("Write it yourself")!;
    expect(writeItYourself).toBeDefined();

    await act(async () => writeItYourself.click());
    const dialog = document.querySelector('[role="dialog"]');
    expect(dialog).not.toBeNull();
    expect(h.sent).toEqual([]);

    cleanup(h);
  });

  it("offers a blank composer, not Draft thank-you, when there is no thread to answer", async () => {
    const h = await mount({ now: new Date("2026-09-21T15:00:00-07:00"), drafts: [] });
    expect(h.button("Draft thank-you")).toBeUndefined();
    const writeBtn = h.button("Write thank-you")!;
    expect(writeBtn).toBeDefined();

    await act(async () => writeBtn.click());
    const dialog = document.querySelector('[role="dialog"]');
    expect(dialog).not.toBeNull();
    expect(h.drafted).toEqual([]); // nothing to draft against — never called
    expect(h.sent).toEqual([]);

    cleanup(h);
  });

  it("closes the follow-through window at 48 hours — no nudge, but the card still opens", async () => {
    const h = await mount({ now: new Date("2026-09-23T14:00:00-07:00") }); // ~49h after end
    expect(h.host.textContent).not.toContain("A thank-you within a day");
    expect(h.host.textContent).toContain("A short note still beats none");
    cleanup(h);
  });
});

describe("PrepCard — assistant off", () => {
  it("never shows Summarise or Draft thank-you when the grant has no assistant", async () => {
    const noAssist: Capability = { ...CAN, canDraft: false, canSummarize: false };
    const h = await mount({ now: new Date("2026-09-21T15:00:00-07:00"), capability: noAssist });
    expect(h.button("Summarise")).toBeUndefined();
    expect(h.button("Draft thank-you")).toBeUndefined();
    expect(h.button("Write thank-you")).toBeDefined();
    cleanup(h);
  });
});
