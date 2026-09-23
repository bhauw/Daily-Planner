/*
 * The workbench as a whole, rendered against a stub engine.
 *
 * Pinned: drafting is offered only when an assistant is actually on (the six chips used to show,
 * and "Write it", with the assistant switched off); the reply can still be written by hand
 * either way; and the workbench says where drafting sends his mail, as the composer does.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Api, Assist, Draft, Settings } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { DraftWorkbench } from "./DraftWorkbench";

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
});

export const THREADS: Draft[] = [
  { id: "u2", title: "Your interview is confirmed", summary: "Thursday 14:30 with the audit team.", kind: "reply",
    sender: "recruiting@example.com", category: "career", receivedAt: null, threadId: "t-u2" },
  { id: "u1", title: "Security alert: new sign-in", summary: "A new sign-in from a device we do not recognise.",
    kind: "reply", sender: "no-reply@accounts.example.com", category: "other", receivedAt: null, threadId: "t-u1",
    reason: "security" },
  { id: "d4", title: "ECONOMICS 250 — midterm room change",
    summary: "The Thursday midterm moves to AQ 3150. No action needed unless you had a conflict.", kind: "reply",
    sender: "registrar@example.edu", category: "school", receivedAt: null, threadId: "t-d4" },
] as Draft[];

export function stubApi(assist: Assist | undefined, drafts: Draft[] = THREADS): Api {
  const settings = {
    vaultSelected: true, scanTimes: [],
    safety: { mode: "writes", externalWrites: true, label: "" },
    source: { kind: "sample", live: false, label: "" },
    capability: { canSend: true, canSchedule: true, canReschedule: true, canDraft: assist?.enabled ?? false,
      canReadBody: false, canSummarize: false },
    ...(assist ? { assist } : {}),
  } as Settings;
  return {
    drafts: async () => ({ drafts }),
    settings: async () => settings,
    draftReply: async () => ({ body: "Drafted.", provider: "Local" }),
    mailBody: async () => { throw new Error("no"); },
    summarizeMail: async () => { throw new Error("no"); },
    week: async () => { throw new Error("no"); },
  } as unknown as Api;
}

const unused = async () => {
  throw new Error("not used");
};
const client = { sendMail: unused, createEvent: unused, moveEvent: unused, draftReply: unused } as never;

export async function mountWorkbench(api: Api) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(
      createElement(WriteDeskProvider, {
        capability: { canSend: true, canSchedule: true, canReschedule: true, canDraft: true, canReadBody: false, canSummarize: false },
        client,
        children: createElement(DraftWorkbench, { api, detached: false }),
      }),
    );
  });
  // Two async loads (drafts, then settings) settle.
  await act(async () => {});
  await act(async () => {});
  return host;
}

const chipLabels = () => [...host!.querySelectorAll(".reply__quick button")].map((b) => b.textContent);

describe("drafting in the workbench follows the assistant setting", () => {
  it("offers no drafting at all with the assistant off, and still lets him write", async () => {
    await mountWorkbench(stubApi({ enabled: false, provider: "", contentLeavesMachine: false, label: "" }));
    expect(chipLabels()).toEqual([]);
    expect(host!.querySelector(".compose__custominput")).toBeNull();
    expect(host!.querySelector(".reply__body")).not.toBeNull();
    expect(host!.textContent).toContain("No assistant is on");
  });

  it("offers no drafting against an engine that reports no assistant", async () => {
    await mountWorkbench(stubApi(undefined));
    expect(chipLabels()).toEqual([]);
  });

  it("says drafting sends the message off this Mac when it does", async () => {
    await mountWorkbench(stubApi({ enabled: true, provider: "Claude", contentLeavesMachine: true, label: "" }));
    expect(chipLabels()).toContain("Accept");
    expect(host!.querySelector(".reply__hint")!.textContent).toContain(
      "sends the subject, the sender and the snippet to Claude",
    );
  });

  it("says it stays on this Mac when it does", async () => {
    await mountWorkbench(stubApi({ enabled: true, provider: "Local model", contentLeavesMachine: false, label: "" }));
    expect(host!.querySelector(".reply__hint")!.textContent).toContain("runs on your Mac");
  });
});

const ON: Assist = { enabled: true, provider: "Local model", contentLeavesMachine: false, label: "" };
const option = (name: RegExp) =>
  [...host!.querySelectorAll("[role=option]")].find((o) => name.test(o.textContent ?? "")) as HTMLElement;
const footerButton = (label: string) =>
  [...host!.querySelectorAll(".editor__actions button")].find((b) => b.textContent?.trim() === label) as
    | HTMLButtonElement
    | undefined;
async function select(name: RegExp) {
  await act(async () => option(name).click());
  await act(async () => {});
}
function typeReply(value: string) {
  const el = host!.querySelector(".reply__body") as HTMLTextAreaElement;
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(el, value);
  el.dispatchEvent(new Event("input", { bubbles: true }));
}

/*
 * "Reply needed" and "This draft sends an email" were on every thread — a no-reply security
 * alert and a registrar note saying "No action needed" included. Alarm fatigue on the one
 * warning that matters.
 */
describe("saying a reply is needed only when one is", () => {
  it("flags the interview, not the no-reply alert or the 'no action needed' note", async () => {
    await mountWorkbench(stubApi(ON));
    expect(option(/interview is confirmed/).textContent).toContain("Reply needed");
    expect(option(/Security alert/).textContent).not.toContain("Reply needed");
    expect(option(/midterm room change/).textContent).not.toContain("Reply needed");
  });

  it("warns that it sends only once there is a reply that would", async () => {
    await mountWorkbench(stubApi(ON));
    expect(host!.textContent).not.toContain("sends an email");
    await act(async () => typeReply("Thursday works."));
    expect(host!.textContent).toContain("sends an email");
    await select(/Security alert/);
    await act(async () => typeReply("Hello?"));
    expect(host!.textContent).not.toContain("sends an email");
  });

  it("prints no empty <> after a sender with no address", async () => {
    await mountWorkbench(stubApi(ON));
    expect(host!.querySelector(".review")!.textContent).not.toContain("<>");
    expect(host!.querySelector(".review")!.textContent).toContain("recruiting@example.com");
  });
});

describe("Reject", () => {
  it("can be undone", async () => {
    await mountWorkbench(stubApi(ON));
    await act(async () => typeReply("Thursday works."));
    await act(async () => footerButton("Reject")!.click());
    expect((host!.querySelector(".reply__body") as HTMLTextAreaElement).disabled).toBe(true);

    await act(async () => footerButton("Undo")!.click());
    const box = host!.querySelector(".reply__body") as HTMLTextAreaElement;
    expect(box.disabled).toBe(false);
    expect(box.value).toBe("Thursday works.");
    expect(footerButton("Reject")!.disabled).toBe(false);
  });
});
