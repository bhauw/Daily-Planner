/*
 * Offering to book what an email proposes. Pinned: a found time opens the scheduler with that
 * time and a clean title; an accepted draft asks outright even with no date found; and without
 * a calendar grant nothing is offered at all.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Capability } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { BookIt } from "./BookIt";
import { isAgreeing } from "./DraftEditor";

const unused = async () => {
  throw new Error("not used");
};
const client = { sendMail: unused, createEvent: unused, moveEvent: unused, draftReply: unused } as never;
const CAN = { canSend: true, canSchedule: true, canReschedule: true, canDraft: true, canReadBody: true, canSummarize: true };

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
});

async function render(props: Parameters<typeof BookIt>[0], capability: Capability = CAN) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(createElement(WriteDeskProvider, { capability, client, children: createElement(BookIt, props) }));
  });
  return host;
}

const buttons = () => [...host!.querySelectorAll("button")];
const future = new Date(Date.now() + 2 * 86_400_000).toISOString();

describe("BookIt", () => {
  it("offers a time found in the email and opens the scheduler with it", async () => {
    await render({ text: "Would Friday at 2pm work?", subject: "Re: Coffee chat?", receivedAt: future, accepted: false });
    expect(host!.textContent).toContain("Dates in this email");
    const add = buttons().find((b) => b.textContent?.startsWith("Add "))!;
    expect(add.textContent).toMatch(/2:00/);

    await act(async () => add.click());
    const title = document.querySelector<HTMLInputElement>(".compose__field input");
    expect(title?.value).toBe("Coffee chat");
    expect(document.body.textContent).toContain("From the email: “Friday at 2pm”");
  });

  it("asks outright once he has drafted a yes, even with no date found", async () => {
    await render({ text: "Keen to chat sometime!", subject: "Coffee?", receivedAt: null, accepted: true });
    expect(host!.textContent).toContain("You’re accepting — put it in your calendar?");
    expect(buttons().map((b) => b.textContent)).toContain("Add to calendar…");
  });

  it("offers nothing when the email names no date and he has not accepted", async () => {
    await render({ text: "Thanks for the notes.", subject: "Notes", receivedAt: null, accepted: false });
    expect(host!.querySelector(".bookit")).toBeNull();
  });

  it("offers nothing without a calendar grant", async () => {
    await render(
      { text: "Friday at 2pm?", subject: "Chat", receivedAt: future, accepted: true },
      { ...CAN, canSchedule: false },
    );
    expect(host!.querySelector(".bookit")).toBeNull();
  });
});

describe("isAgreeing", () => {
  it("reads the Accept button and agreeing instructions as yes, and declines as no", () => {
    expect(isAgreeing("accept")).toBe(true);
    expect(isAgreeing("decline")).toBe(false);
    expect(isAgreeing("accept", "say Thursday works for me")).toBe(true);
    expect(isAgreeing("accept", "tell them I can't make it")).toBe(false);
    expect(isAgreeing("accept", "ask what the agenda is")).toBe(false);
  });
});
