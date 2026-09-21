/*
 * The one rule the composer exists to enforce: nothing sends until the user has
 * seen who it is going to and pressed Send on that screen.
 *
 * Asserted here rather than left to the component's shape, because "the review
 * step" is easy to keep as a visual and lose as a guarantee — a stray onSubmit,
 * an Enter key that reaches the form, a refactor that collapses the phases —
 * and the failure is an email that has already gone.
 */

// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ApiError, type SendMailRequest, type SendMailResponse } from "../api/client";
import { Composer, parseRecipients } from "./Composer";
import type { ComposePrefill } from "./types";

const prefill: ComposePrefill = {
  to: ["leasing@example.test"],
  subject: "Re: Lease Bonuses",
  body: "Thanks — Thursday works.",
  threadId: "t-1",
};

interface Mounted {
  host: HTMLElement;
  root: Root;
  click: (text: string) => Promise<void>;
  text: () => string;
  button: (text: string) => HTMLButtonElement | undefined;
}

async function mount(
  send: (request: SendMailRequest) => Promise<SendMailResponse>,
  onClose = () => {},
): Promise<Mounted> {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(createElement(Composer, { prefill, send, onClose }));
  });

  const button = (text: string) =>
    Array.from(host.querySelectorAll("button")).find(
      (b) => b.textContent?.trim() === text,
    ) as HTMLButtonElement | undefined;

  return {
    host,
    root,
    button,
    text: () => host.textContent ?? "",
    click: async (text: string) => {
      const target = button(text);
      if (!target) throw new Error(`no button labelled "${text}" — found: ${
        Array.from(host.querySelectorAll("button")).map((b) => b.textContent?.trim()).join(", ")
      }`);
      await act(async () => {
        target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      });
    },
  };
}

describe("nothing sends without the review step", () => {
  it("does not send when Review is pressed", async () => {
    const send = vi.fn().mockResolvedValue({ ok: true, id: "m1", threadId: "t-1" });
    const ui = await mount(send);

    await ui.click("Review");

    expect(send).not.toHaveBeenCalled();
    // And the user is now looking at exactly who it would go to.
    expect(ui.text()).toContain("Send this?");
    expect(ui.text()).toContain("leasing@example.test");
  });

  it("sends once, and only from the review screen", async () => {
    const send = vi.fn().mockResolvedValue({ ok: true, id: "m1", threadId: "t-1" });
    const ui = await mount(send);

    await ui.click("Review");
    await ui.click("Send");

    expect(send).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledWith({
      to: ["leasing@example.test"],
      subject: "Re: Lease Bonuses",
      body: "Thanks — Thursday works.",
      threadId: "t-1",
    });
    expect(ui.text()).toContain("Sent");
  });

  it("goes back to editing with the message intact", async () => {
    const send = vi.fn();
    const ui = await mount(send);

    await ui.click("Review");
    await ui.click("Back to edit");

    expect(send).not.toHaveBeenCalled();
    const body = ui.host.querySelector("textarea") as HTMLTextAreaElement;
    expect(body.value).toBe("Thanks — Thursday works.");
  });
});

describe("a refused send", () => {
  it("shows the engine's own words and does not retry on its own", async () => {
    // The engine writes a sentence for this exact failure — "Check the recipient address." is
    // worth more than "something went wrong", and it is safe to show because it quotes nothing
    // the user typed.
    const send = vi.fn().mockRejectedValue(new ApiError("invalid_request", "Check the recipient address."));
    const ui = await mount(send);

    await ui.click("Review");
    await ui.click("Send");

    expect(send).toHaveBeenCalledTimes(1);
    expect(ui.text()).toContain("Check the recipient address.");
    // Still on review, with Send available again — the user retries, not the app. A send that
    // may or may not have gone through must never be repeated on their behalf.
    expect(ui.text()).toContain("Send this?");
    expect(ui.button("Send")).toBeDefined();
  });

  it("falls back to a safe sentence when the failure carries no message", async () => {
    const send = vi.fn().mockRejectedValue(new Error("TypeError: fetch failed at https://…"));
    const ui = await mount(send);

    await ui.click("Review");
    await ui.click("Send");

    // Never the raw error: it can carry a URL or a host.
    expect(ui.text()).not.toContain("https://");
    expect(ui.text()).toContain("Nothing was sent.");
  });
});

describe("recipient parsing", () => {
  it("splits the ways people actually type a list", () => {
    expect(parseRecipients("a@b.com, c@d.com")).toEqual(["a@b.com", "c@d.com"]);
    expect(parseRecipients("a@b.com; c@d.com")).toEqual(["a@b.com", "c@d.com"]);
    expect(parseRecipients("a@b.com\nc@d.com")).toEqual(["a@b.com", "c@d.com"]);
    expect(parseRecipients("  a@b.com ,, ")).toEqual(["a@b.com"]);
    expect(parseRecipients("   ")).toEqual([]);
  });
});
