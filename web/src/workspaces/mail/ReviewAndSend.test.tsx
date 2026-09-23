/*
 * Approve used to do nothing on a real thread — it was disabled there, and the footer said
 * "nothing was sent". Pinned: Review & send hands the reply to the app's one composer, with the
 * thread and the text he wrote, and nothing is sent until that composer's own Send.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Capability, Draft, SendMailRequest } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { DraftEditor, triageNote } from "./DraftEditor";
import { detailFor } from "./data";
import { initialState, editBody } from "./machine";

const sent: SendMailRequest[] = [];
const unused = async () => {
  throw new Error("not used");
};
const client = {
  sendMail: async (r: SendMailRequest) => {
    sent.push(r);
    return { ok: true, id: "m", threadId: r.threadId ?? null };
  },
  createEvent: unused,
  moveEvent: unused,
  draftReply: unused,
} as never;
const CAN: Capability = {
  canSend: true, canSchedule: true, canReschedule: true, canDraft: false, canReadBody: false, canSummarize: false,
};

const draft: Draft = {
  id: "m1", title: "Coffee chat?", summary: "Free Thursday?", kind: "reply",
  sender: "sarah@example.com", category: "career", receivedAt: null, threadId: "t1",
} as Draft;

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  sent.length = 0;
});

async function render(body: string, capability = CAN) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  const detail = detailFor(draft);
  const state = editBody(initialState(detail.subject, detail.body), body);
  const noop = () => {};
  await act(async () => {
    root!.render(
      createElement(WriteDeskProvider, {
        capability,
        client,
        children: createElement(DraftEditor, {
          draft, detail, state,
          onEditSubject: noop, onEditBody: noop, onPreflight: noop, onApprove: noop, onReject: noop,
        }),
      }),
    );
  });
}

const button = (label: string) =>
  [...document.querySelectorAll("button")].find((b) => b.textContent === label) as HTMLButtonElement | undefined;

describe("Review & send on a real thread", () => {
  it("opens the composer with his reply, on the thread, and sends nothing by itself", async () => {
    await render("Hi Sarah,\n\nThursday works.\n\nBest,\nBraxton");
    const review = button("Review & send")!;
    expect(review.disabled).toBe(false);

    await act(async () => review.click());
    const dialog = document.querySelector("[role=dialog]")!;
    expect(dialog).not.toBeNull();
    expect((dialog.querySelector("textarea") as HTMLTextAreaElement).value).toContain("Thursday works.");
    expect(dialog.textContent).toContain("Replying to sarah@example.com");
    expect(sent).toEqual([]);
  });

  it("has no Preflight or Approve that could imply it already went", async () => {
    await render("x");
    expect(button("Approve")).toBeUndefined();
    expect(button("Preflight")).toBeUndefined();
  });

  it("stays disabled with nothing written, or without a send grant", async () => {
    await render("   ");
    expect(button("Review & send")!.disabled).toBe(true);
    act(() => root!.unmount());
    await render("Hi", { ...CAN, canSend: false });
    expect(button("Review & send")!.disabled).toBe(true);
  });
});

describe("triageNote", () => {
  it("says where the reply goes next, or why it cannot", () => {
    expect(triageNote(true, false, "Hi")).toBe("Opens the send window · nothing goes until you press Send there");
    expect(triageNote(false, false, "Hi")).toContain("reading only");
    expect(triageNote(true, false, " ")).toBe("Write or draft a reply to send it");
    expect(triageNote(true, true, "Hi")).toContain("Rejected");
  });
});

describe("triageNote without a send window", () => {
  it("does not blame the account when the window simply has no composer", () => {
    const note = triageNote(false, false, "Hi", false);
    expect(note).not.toContain("reading only");
    expect(note).toContain("main window");
  });
});
