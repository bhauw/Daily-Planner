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

  // The shell drops the answered message from every list the moment the send lands, instead of
  // leaving it there until a full reload — so the composer says which message it answered.
  it("tells the host which message it answered, once, after the send", async () => {
    const send = vi.fn().mockResolvedValue({ ok: true, id: "m1", threadId: "t-1" });
    const onWrote = vi.fn();
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    await act(async () => {
      root.render(createElement(Composer, { prefill: { ...prefill, answers: "d1" }, send, onClose: () => {}, onWrote }));
    });
    const press = async (label: string) => {
      const b = Array.from(host.querySelectorAll("button")).find((x) => x.textContent?.trim() === label)!;
      await act(async () => b.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    };
    await press("Review");
    await press("Send");

    expect(onWrote).toHaveBeenCalledTimes(1);
    expect(onWrote).toHaveBeenCalledWith({ kind: "mail", answers: "d1" });
    act(() => root.unmount());
    host.remove();
  });

  it("warns on the review screen before sending to an address nobody reads", async () => {
    const send = vi.fn();
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    await act(async () => {
      root.render(createElement(Composer, { prefill: { ...prefill, to: ["no-reply@accounts.example.com"] }, send, onClose: () => {} }));
    });
    const b = Array.from(host.querySelectorAll("button")).find((x) => x.textContent?.trim() === "Review")!;
    await act(async () => b.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(host.textContent).toMatch(/no-reply@accounts\.example\.com does not accept replies/i);
    expect(send).not.toHaveBeenCalled();
    act(() => root.unmount());
    host.remove();
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

  // The write->review swap unmounts the whole form and mounts compose__review in its place;
  // nothing moved focus onto the new screen, so a keyboard/screen-reader user landed on <body>
  // with no idea the screen had changed (audit finding #2). The draft-result path just above
  // already does this correctly (bodyRef.current?.focus()) — review() gets the same treatment.
  it("moves focus onto the review screen when Review is pressed", async () => {
    const send = vi.fn();
    const ui = await mount(send);

    await ui.click("Review");

    const heading = ui.host.querySelector(".compose__title") as HTMLElement;
    expect(heading.textContent).toBe("Send this?");
    expect(document.activeElement).toBe(heading);
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

/*
 * Drafting used to replace whatever he had typed, silently and with no way back, and the
 * textarea stayed editable while the request ran — so words typed during it were lost too.
 */
describe("drafting over his own words", () => {
  it("locks the message while writing, then offers Undo back to what he had", async () => {
    let finish!: (v: { body: string; provider: string }) => void;
    const draft = vi.fn(() => new Promise<{ body: string; provider: string }>((r) => (finish = r)));
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    await act(async () => {
      root.render(
        createElement(Composer, {
          prefill: { ...prefill, body: "My own careful words.", draftFrom: "m1" },
          send: vi.fn(),
          draft: draft as never,
          onClose: () => {},
        }),
      );
    });
    const textarea = () => host.querySelector("textarea") as HTMLTextAreaElement;
    const button = (t: string) =>
      [...host.querySelectorAll("button")].find((b) => b.textContent?.trim() === t) as HTMLButtonElement | undefined;

    await act(async () => button("Decline")!.click());
    expect(textarea().disabled).toBe(true);

    await act(async () => finish({ body: "Thanks, but I can't make it.", provider: "Local" }));
    expect(textarea().disabled).toBe(false);
    expect(textarea().value).toBe("Thanks, but I can't make it.");

    await act(async () => button("Undo")!.click());
    expect(textarea().value).toBe("My own careful words.");
    expect(button("Undo")).toBeUndefined();
    act(() => root.unmount());
    host.remove();
  });
});

describe("a typed instruction in the composer", () => {
  it("goes out on the neutral intent, never as an 'accept'", async () => {
    const draft = vi.fn().mockResolvedValue({ body: "No, thanks.", provider: "Local" });
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    await act(async () => {
      root.render(
        createElement(Composer, {
          prefill: { ...prefill, draftFrom: "m1" }, send: vi.fn(), draft, onClose: () => {},
        }),
      );
    });
    const input = host.querySelector("#draft-instruction") as HTMLInputElement;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "Politely decline");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const write = [...host.querySelectorAll("button")].find((b) => b.textContent?.trim() === "Write it")!;
    await act(async () => write.click());
    expect(draft).toHaveBeenCalledWith({ messageId: "m1", intent: "acknowledge", instruction: "Politely decline" });
    act(() => root.unmount());
    host.remove();
  });
});
