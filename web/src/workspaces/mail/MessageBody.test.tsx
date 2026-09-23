/*
 * The email in the middle pane.
 *
 * Pinned: the real body replaces the snippet once it arrives; nothing is summarised until he
 * presses the button; a withheld or failed body says why instead of going blank; and switching
 * messages never shows the last message's body or summary on the next one.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { MailBody } from "../../api/client";
import { MessageBody } from "./MessageBody";

let root: Root | null = null;
let host: HTMLElement | null = null;

afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
});

function body(id: string, text: string | null, extra: Partial<MailBody> = {}): MailBody {
  return { id, text, truncated: false, attachments: [], unreadable: null, ...extra };
}

async function render(props: Parameters<typeof MessageBody>[0]) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(createElement(MessageBody, props));
  });
  return host;
}

async function rerender(props: Parameters<typeof MessageBody>[0]) {
  await act(async () => {
    root!.render(createElement(MessageBody, props));
  });
}

function button(label: string): HTMLButtonElement | undefined {
  return [...host!.querySelectorAll("button")].find((b) => b.textContent === label) as
    | HTMLButtonElement
    | undefined;
}

describe("MessageBody", () => {
  it("replaces the snippet with the full email once it arrives", async () => {
    const el = await render({
      messageId: "m1",
      snippet: "Short preview",
      readBody: async (id) => body(id, "The whole email, all of it."),
    });
    expect(el.querySelector(".message__body")?.textContent).toBe("The whole email, all of it.");
    expect(el.textContent).not.toContain("Short preview");
  });

  it("summarises only when asked, and says the email is sent", async () => {
    const asked: string[] = [];
    const el = await render({
      messageId: "m1",
      snippet: "s",
      readBody: async (id) => body(id, "Room moves to AQ 3150."),
      summarize: async (id) => {
        asked.push(id);
        return { summary: "- Room change", provider: "Claude (your subscription)" };
      },
    });
    expect(asked).toEqual([]);
    expect(el.textContent).toContain("Sends this email to your assistant");

    await act(async () => button("Summarise")!.click());
    expect(asked).toEqual(["m1"]);
    expect(el.querySelector(".message__summary")?.textContent).toContain("- Room change");
    expect(el.textContent).toContain("Summary by Claude (your subscription)");
  });

  it("offers no summary without an assistant, or when there is no body to summarise", async () => {
    let el = await render({ messageId: "m1", snippet: "s", readBody: async (id) => body(id, "Text") });
    expect(button("Summarise")).toBeUndefined();
    act(() => root!.unmount());

    el = await render({
      messageId: "m1",
      snippet: "Preview",
      readBody: async (id) => body(id, null, { unreadable: "This message could not be read safely, so its body is not shown." }),
      summarize: async () => ({ summary: "x", provider: "p" }),
    });
    expect(button("Summarise")).toBeUndefined();
    expect(el.textContent).toContain("could not be read safely");
    expect(el.querySelector(".message__body")?.textContent).toBe("Preview");
  });

  it("falls back to the preview, and says so, when the body cannot be loaded", async () => {
    const el = await render({
      messageId: "m1",
      snippet: "Preview",
      readBody: async () => {
        throw new Error("nope");
      },
    });
    expect(el.querySelector(".message__body")?.textContent).toBe("Preview");
    expect(el.textContent).toContain("The full email could not be loaded");
  });

  it("shows the refusal when a summary is declined", async () => {
    const el = await render({
      messageId: "m1",
      snippet: "s",
      readBody: async (id) => body(id, "Your code is 1234"),
      summarize: async () => {
        throw new Error("That message looks like it holds a code, a password or an account detail, so it is not sent to an assistant.");
      },
    });
    await act(async () => button("Summarise")!.click());
    expect(el.textContent).toContain("so it is not sent to an assistant");
  });

  it("never carries one message's summary onto the next", async () => {
    const readBody = async (id: string) => body(id, `Body of ${id}`);
    const summarize = async () => ({ summary: "- About m1", provider: "p" });
    const el = await render({ messageId: "m1", snippet: "s", readBody, summarize });
    await act(async () => button("Summarise")!.click());
    expect(el.textContent).toContain("- About m1");

    await rerender({ messageId: "m2", snippet: "s", readBody, summarize });
    expect(el.textContent).not.toContain("- About m1");
    expect(el.querySelector(".message__body")?.textContent).toBe("Body of m2");
  });

  it("lists attachments by name and says they were not downloaded", async () => {
    const el = await render({
      messageId: "m1",
      snippet: "s",
      readBody: async (id) => body(id, "See attached", { attachments: ["room-map.pdf"] }),
    });
    expect(el.textContent).toContain("Attachments (not downloaded): room-map.pdf");
  });

  it("keeps focus on Summarise while it works, and announces that it is working", async () => {
    let finish!: (v: { summary: string; provider: string }) => void;
    const el = await render({
      messageId: "m1",
      snippet: "Preview",
      readBody: async (id) => body(id, "The whole email."),
      summarize: () => new Promise((r) => (finish = r)),
    });
    const go = button("Summarise")!;
    go.focus();
    await act(async () => go.click());
    // Not disabled: a disabled button cannot hold focus, and the browser drops it to <body>.
    expect(button("Summarising…")!.disabled).toBe(false);
    expect(button("Summarising…")!.getAttribute("aria-disabled")).toBe("true");
    expect(document.activeElement).toBe(button("Summarising…"));
    const live = [...el.querySelectorAll("[aria-live=polite]")].map((n) => n.textContent).join(" ");
    expect(live).toContain("Summarising");
    await act(async () => finish({ summary: "Short.", provider: "Local" }));
    expect(document.activeElement).toBe(button("Summarise again"));
  });
});
