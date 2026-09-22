/*
 * The write desk is the only modal in the app, and it is the modal you are standing in when
 * you are about to send something irreversible. Two guarantees are asserted here.
 *
 * 1. Tab does not leave the dialog. It used to: measured with real dispatched keystrokes,
 *    focus escaped at stop 24 of 44 and 21 stops landed on controls behind the scrim —
 *    invisible, unreachable by mouse, and one of them a nav link that would have unmounted
 *    the composer with a typed reply still in it.
 * 2. The app behind the dialog is `inert` and `aria-hidden` while it is open, so
 *    `aria-modal="true"` states something true. Without it a screen reader could walk the
 *    whole day behind a dialog claiming to be modal.
 *
 * jsdom does not move focus on Tab by itself, so these dispatch real keydown events and
 * assert what the trap does with them — which is the behaviour under test anyway.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type {
  CreateEventRequest,
  CreateEventResponse,
  DraftReplyRequest,
  DraftReplyResponse,
  MoveEventRequest,
  SendMailRequest,
  SendMailResponse,
} from "../api/client";
import { WriteDeskProvider, useWriteDesk } from "./WriteDesk";

const capability = {
  canSend: true,
  canSchedule: true,
  canReschedule: true,
  canDraft: false,
  canReadBody: false,
  canSummarize: false,
};

const client = {
  sendMail: async (_request: SendMailRequest): Promise<SendMailResponse> => {
    throw new Error("not used");
  },
  createEvent: async (_request: CreateEventRequest): Promise<CreateEventResponse> => {
    throw new Error("not used");
  },
  moveEvent: async (_request: MoveEventRequest): Promise<CreateEventResponse> => {
    throw new Error("not used");
  },
  draftReply: async (_request: DraftReplyRequest): Promise<DraftReplyResponse> => {
    throw new Error("not used");
  },
};

/** A button in the page behind the desk — the thing Tab must never reach while it is open. */
function Background() {
  const desk = useWriteDesk();
  return createElement(
    "button",
    {
      id: "behind",
      onClick: () =>
        desk?.compose({ to: ["someone@example.test"], subject: "Re: hello", body: "Hi." }),
    },
    "Open the composer",
  );
}

interface Mounted {
  host: HTMLElement;
  root: Root;
  panel: () => HTMLElement | null;
  background: () => HTMLElement | null;
  tab: (shift?: boolean) => Promise<void>;
}

async function mount(): Promise<Mounted> {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);

  await act(async () => {
    root.render(
      createElement(WriteDeskProvider, {
        capability,
        client,
        assist: undefined,
        children: createElement(Background),
      }),
    );
  });

  return {
    host,
    root,
    panel: () => host.querySelector<HTMLElement>(".compose__panel"),
    // The provider's inert wrapper is the first element child of the host.
    background: () => host.firstElementChild as HTMLElement | null,
    tab: async (shift = false) => {
      await act(async () => {
        window.dispatchEvent(
          new KeyboardEvent("keydown", { key: "Tab", shiftKey: shift, bubbles: true, cancelable: true }),
        );
      });
    },
  };
}

async function openDesk(m: Mounted) {
  const opener = m.host.querySelector<HTMLButtonElement>("#behind");
  await act(async () => {
    opener?.click();
  });
}

function cleanup(m: Mounted) {
  act(() => m.root.unmount());
  m.host.remove();
}

describe("WriteDesk focus containment", () => {
  it("marks the app behind the dialog inert and aria-hidden while open, and restores it on close", async () => {
    const m = await mount();
    const background = m.background();

    expect(background?.hasAttribute("inert")).toBe(false);
    expect(background?.getAttribute("aria-hidden")).toBeNull();

    await openDesk(m);
    expect(m.panel()).not.toBeNull();
    expect(background?.hasAttribute("inert")).toBe(true);
    expect(background?.getAttribute("aria-hidden")).toBe("true");

    await act(async () => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });

    expect(m.panel()).toBeNull();
    expect(background?.hasAttribute("inert")).toBe(false);
    expect(background?.getAttribute("aria-hidden")).toBeNull();

    cleanup(m);
  });

  it("keeps Tab inside the panel instead of walking out to the page behind", async () => {
    const m = await mount();
    await openDesk(m);
    const panel = m.panel();
    expect(panel).not.toBeNull();

    // Focus starts on the panel itself; the first Tab must enter the form. Asserting it
    // MOVED matters: jsdom does not action Tab on its own, so `panel.contains(panel)` would
    // be vacuously true and this test would pass with no trap at all.
    expect(document.activeElement).toBe(panel);
    await m.tab();
    expect(document.activeElement).not.toBe(panel);
    expect(panel!.contains(document.activeElement)).toBe(true);
    expect(document.activeElement?.tagName).toMatch(/INPUT|TEXTAREA|BUTTON|SELECT|A/);

    // Walk well past the number of controls the dialog has. Every stop stays inside.
    for (let i = 0; i < 40; i += 1) {
      await m.tab();
      expect(panel!.contains(document.activeElement), `forward tab ${i}`).toBe(true);
      expect(document.activeElement?.id).not.toBe("behind");
    }

    cleanup(m);
  });

  it("wraps backwards too, so Shift+Tab off the first control does not escape", async () => {
    const m = await mount();
    await openDesk(m);
    const panel = m.panel();

    await m.tab(); // enter the form
    for (let i = 0; i < 40; i += 1) {
      await m.tab(true);
      expect(panel!.contains(document.activeElement), `back tab ${i}`).toBe(true);
      expect(document.activeElement?.id).not.toBe("behind");
    }

    cleanup(m);
  });

  it("pulls focus back if it somehow lands outside while the dialog is open", async () => {
    const m = await mount();
    await openDesk(m);
    const panel = m.panel();

    const outside = m.host.querySelector<HTMLButtonElement>("#behind");
    await act(async () => {
      outside?.focus();
    });
    await m.tab();

    expect(panel!.contains(document.activeElement)).toBe(true);

    cleanup(m);
  });
});
