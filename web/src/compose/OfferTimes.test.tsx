/*
 * The "Offer times" flow, rendered: chip → picker → "Draft with these times" → the draft lands in
 * the reply. Pinned in both places that draft replies (the Mail workbench and the composer),
 * because the guarantees are the same in each and are only true if both keep them:
 *
 *  - the request carries an id, the followUp intent and an instruction of slot times — nothing
 *    from the calendar but times;
 *  - nothing is sent. The draft fills a field, and Send stays behind the existing review step.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import {
  ApiError,
  type Capability,
  type Draft,
  type DraftReplyRequest,
  type PlannerEvent,
  type SendMailRequest,
  type WeekResponse,
} from "../api/client";
import { isoAtVan } from "../workspaces/calendar/tz";
import { DraftEditor } from "../workspaces/mail/DraftEditor";
import { detailFor } from "../workspaces/mail/data";
import { initialState } from "../workspaces/mail/machine";
import { WriteDeskProvider } from "./WriteDesk";
import { Composer } from "./Composer";

const SECRET = "Confidential — Example Corp partner interview";
const PLACE = "PwC Tower, 12th floor";
const event = (day: number, from: number, to: number, title: string, location: string | null): PlannerEvent => ({
  id: `${day}-${from}`, title, category: "career", kind: "event",
  start: isoAtVan(2026, 9, day, from, 0), end: isoAtVan(2026, 9, day, to, 0),
  due: null, location, calendarId: "primary",
});
const WEEK: WeekResponse = {
  start: "2026-09-23",
  days: 7,
  events: [event(24, 9, 12, SECRET, PLACE), event(28, 13, 15, "Investment Club", "SUB 2270")],
};

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = host = null;
});

async function mount(node: ReturnType<typeof createElement>) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => root!.render(node));
}
const buttons = () => [...document.querySelectorAll("button")] as HTMLButtonElement[];
const button = (label: string | RegExp) =>
  buttons().find((b) => (typeof label === "string" ? b.textContent?.trim() === label : label.test(b.textContent ?? "")));
const click = async (label: string | RegExp) => {
  const b = button(label);
  if (!b) throw new Error(`no button "${label}" — ${buttons().map((x) => x.textContent).join(" | ")}`);
  await act(async () => b.click());
};
const slotChips = () => [...document.querySelectorAll<HTMLButtonElement>('[aria-label="Suggested times"] button')];

// ---- Mail workbench ----

const sent: SendMailRequest[] = [];
const client = {
  sendMail: async (r: SendMailRequest) => {
    sent.push(r);
    return { ok: true, id: "m", threadId: null };
  },
  createEvent: async () => { throw new Error("not used"); },
  moveEvent: async () => { throw new Error("not used"); },
  draftReply: async () => { throw new Error("not used"); },
} as never;
const CAN: Capability = {
  canSend: true, canSchedule: false, canReschedule: false, canDraft: true, canReadBody: false, canSummarize: false,
};
const draft = {
  id: "m1", title: "Coffee chat?", summary: "Happy to chat — what works for you?", kind: "reply",
  sender: "recruiter@example.com", category: "career", receivedAt: null, threadId: "t1",
} as Draft;

async function mountWorkbench(readWeek: () => Promise<WeekResponse>) {
  const asked: { id: string; intent: string; instruction?: string }[] = [];
  const bodies: string[] = [];
  const detail = detailFor(draft);
  const noop = () => {};
  await mount(
    createElement(WriteDeskProvider, {
      capability: CAN,
      client,
      children: createElement(DraftEditor, {
        draft, detail, state: initialState(detail.subject, detail.body),
        onEditSubject: noop, onEditBody: (v: string) => bodies.push(v),
        onPreflight: noop, onApprove: noop, onReject: noop,
        onDraft: async (id: string, intent: string, instruction?: string) => {
          asked.push({ id, intent, instruction });
          return "Hi — would Thursday at 12:30 work?";
        },
        readWeek,
      }),
    }),
  );
  return { asked, bodies };
}

describe("Offer times in the Mail workbench", () => {
  it("suggests real free slots, three ticked, and drafts them without sending anything", async () => {
    const { asked, bodies } = await mountWorkbench(async () => WEEK);
    expect(document.querySelector(".offer")).toBeNull();

    await click("Offer times");
    const chips = slotChips();
    expect(chips.length).toBe(5);
    expect(chips.filter((c) => c.getAttribute("aria-pressed") === "true")).toHaveLength(3);

    // Untick the first, tick the fourth — still three, a different three.
    await act(async () => chips[0].click());
    await act(async () => chips[3].click());
    const ticked = slotChips().filter((c) => c.getAttribute("aria-pressed") === "true");
    expect(ticked).toHaveLength(3);

    await click("Draft with these times");
    expect(asked).toHaveLength(1);
    expect(asked[0].id).toBe("m1");
    expect(asked[0].intent).toBe("followUp");
    const instruction = asked[0].instruction!;
    expect(new TextEncoder().encode(instruction).length).toBeLessThanOrEqual(1000);
    expect(instruction.split("\n").filter((l) => l.startsWith("- "))).toHaveLength(3);
    // Only times: no title, no venue, no reason line.
    expect(instruction).not.toContain(SECRET);
    expect(instruction).not.toContain(PLACE);
    expect(instruction).not.toMatch(/Investment Club|SUB 2270|transit/);

    expect(bodies.at(-1)).toBe("Hi — would Thursday at 12:30 work?");
    expect(document.querySelector(".offer")).toBeNull(); // picker closes on the draft landing
    expect(sent).toHaveLength(0);
    expect(document.querySelector("[role=dialog]")).toBeNull();
  });

  it("re-suggests when the length changes", async () => {
    await mountWorkbench(async () => WEEK);
    await click("Offer times");
    const before = slotChips().map((c) => c.textContent);
    await click("60 min");
    expect(slotChips().map((c) => c.textContent)).not.toEqual(before);
    expect(slotChips().every((c) => /–/.test(c.textContent ?? ""))).toBe(true);
  });

  it("says so when there are no free slots, and offers nothing to draft", async () => {
    const full: WeekResponse = {
      ...WEEK,
      events: [24, 25, 28, 29].map((d) => event(d, 8, 21, "Busy", null)),
    };
    await mountWorkbench(async () => full);
    await click("Offer times");
    expect(document.body.textContent).toMatch(/No free 45-minute slots in the next 4 business days/);
    expect(button(/Draft with/)).toBeUndefined();
  });

  it("names a failed calendar read and retries on request", async () => {
    let calls = 0;
    await mountWorkbench(async () => {
      calls++;
      if (calls === 1) throw new ApiError("server_error", "The engine could not read your calendar.");
      return WEEK;
    });
    await click("Offer times");
    expect(document.querySelector("[role=alert]")?.textContent).toMatch(/could not read your calendar/);
    await click("Try again");
    expect(slotChips().length).toBe(5);
  });

  it("is not offered without a calendar to read", async () => {
    await mountWorkbench(undefined as never);
    expect(button("Offer times")).toBeUndefined();
  });
});

// ---- Composer ----

describe("Offer times in the composer", () => {
  it("drafts the ticked times into Message; Send still needs Review then Send", async () => {
    const requests: DraftReplyRequest[] = [];
    const sends: SendMailRequest[] = [];
    await mount(
      createElement(Composer, {
        prefill: { to: ["recruiter@example.com"], subject: "Re: Coffee chat?", draftFrom: "m1" },
        send: async (r: SendMailRequest) => {
          sends.push(r);
          return { ok: true, id: "x", threadId: null };
        },
        draft: async (r: DraftReplyRequest) => {
          requests.push(r);
          return { ok: true, body: "Any of these work?", provider: "Test" };
        },
        readWeek: async () => WEEK,
        onClose: () => {},
      }),
    );
    await click("Offer times");
    expect(slotChips()).toHaveLength(5);
    await click("Draft with these times");

    expect(requests).toHaveLength(1);
    // An id, an intent and the instruction — no calendar data but the times inside it.
    expect(Object.keys(requests[0]).sort()).toEqual(["instruction", "intent", "messageId"]);
    expect(requests[0].intent).toBe("followUp");
    expect(requests[0].instruction).not.toContain(SECRET);
    expect(requests[0].instruction).not.toContain(PLACE);
    expect((document.querySelector(".compose__textarea") as HTMLTextAreaElement).value).toBe("Any of these work?");
    expect(sends).toHaveLength(0);
  });

  it("is hidden when no week reader is given", async () => {
    await mount(
      createElement(Composer, {
        prefill: { to: ["a@example.com"], subject: "Re: x", draftFrom: "m1" },
        send: async () => ({ ok: true, id: "x", threadId: null }),
        draft: async () => ({ ok: true, body: "", provider: "Test" }),
        onClose: () => {},
      }),
    );
    expect(button("Offer times")).toBeUndefined();
  });
});
