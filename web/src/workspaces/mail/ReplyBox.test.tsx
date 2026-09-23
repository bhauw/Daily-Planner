/*
 * The reply box on a real thread, rendered.
 *
 * Pinned here: it stays compact until he uses it (the email needs the height), and it grows as
 * soon as he focuses it, types, or has a reply drafted; and nothing of one thread's reply box —
 * a draft in flight, a typed instruction, a note, the booking prompt — follows him to another.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Capability, Draft } from "../../api/client";
import { WriteDeskProvider } from "../../compose/WriteDesk";
import { DraftEditor } from "./DraftEditor";
import { detailFor } from "./data";
import { editBody, initialState } from "./machine";

const draft: Draft = {
  id: "m1", title: "Coffee chat?", summary: "Free Thursday?", kind: "reply",
  sender: "sarah@example.com", category: "career", receivedAt: null, threadId: "t1",
} as Draft;

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
});

const noop = () => {};

async function render(body: string) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  const detail = detailFor(draft);
  const state = editBody(initialState(detail.subject, detail.body), body);
  await act(async () => {
    root!.render(
      createElement(DraftEditor, {
        draft, detail, state,
        onEditSubject: noop, onEditBody: noop, onPreflight: noop, onApprove: noop, onReject: noop,
        onDraft: async () => "Drafted.",
      }),
    );
  });
}

const reply = () => host!.querySelector(".reply") as HTMLElement;
const textbox = () => host!.querySelector(".reply__body") as HTMLTextAreaElement;

describe("the reply box on a real thread", () => {
  it("is compact while nothing has been written, so the email gets the height", async () => {
    await render("");
    expect(reply().classList.contains("reply--open")).toBe(false);
  });

  it("grows as soon as he focuses it", async () => {
    await render("");
    await act(async () => textbox().focus());
    expect(reply().classList.contains("reply--open")).toBe(true);
    await act(async () => textbox().blur());
    expect(reply().classList.contains("reply--open")).toBe(false);
  });

  it("stays grown while there is a reply in it", async () => {
    await render("Thursday works.");
    expect(reply().classList.contains("reply--open")).toBe(true);
  });
});

/* ---- Switching threads while a draft is in flight ---- */

const other: Draft = {
  id: "m2", title: "Your statement is ready", summary: "September statement.", kind: "reply",
  sender: "alerts@example-bank.com", category: "finance", receivedAt: null, threadId: "t2",
} as Draft;

const CAN: Capability = {
  canSend: true, canSchedule: true, canReschedule: true, canDraft: true, canReadBody: false, canSummarize: false,
};
const unused = async () => {
  throw new Error("not used");
};
const client = { sendMail: unused, createEvent: unused, moveEvent: unused, draftReply: unused } as never;

function deferred() {
  let resolve!: (v: string) => void;
  const promise = new Promise<string>((r) => (resolve = r));
  return { promise, resolve };
}

interface Mounted {
  edits: { id: string; body: string }[];
  show: (d: Draft, body?: string) => Promise<void>;
}

async function mountDesk(
  onDraft: (id: string, intent?: string, instruction?: string) => Promise<string>,
): Promise<Mounted> {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  const edits: { id: string; body: string }[] = [];
  const show = async (d: Draft, body = "") => {
    const detail = detailFor(d);
    const state = editBody(initialState(detail.subject, detail.body), body);
    await act(async () => {
      root!.render(
        createElement(WriteDeskProvider, {
          capability: CAN,
          client,
          children: createElement(DraftEditor, {
            draft: d, detail, state,
            onEditSubject: noop,
            onEditBody: (v: string) => edits.push({ id: d.id, body: v }),
            onPreflight: noop, onApprove: noop, onReject: noop,
            onDraft: (id: string, intent: string, instruction?: string) => onDraft(id, intent, instruction),
          }),
        }),
      );
    });
  };
  return { edits, show };
}

const chip = (label: string) =>
  [...host!.querySelectorAll(".reply__quick button")].find((b) => b.textContent === label) as HTMLButtonElement;
const instructionBox = () => host!.querySelector(".compose__custominput") as HTMLInputElement;

function typeInto(el: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const proto = el instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(el, value);
  el.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("switching threads while a reply is being drafted", () => {
  it("does not carry 'Writing…', the instruction or the note onto the next thread", async () => {
    const pending = deferred();
    const desk = await mountDesk(() => pending.promise);
    await desk.show(draft);
    await act(async () => typeInto(instructionBox(), "Say Thursday works"));
    await act(async () => chip("Accept").click());
    expect(chip("Writing…")).toBeDefined();

    await desk.show(other);
    expect(host!.textContent).not.toContain("Writing…");
    expect(chip("Accept").disabled).toBe(false);
    expect(instructionBox().value).toBe("");

    await act(async () => pending.resolve("Thursday works for me."));
    // The draft lands on the thread it was asked for, and nowhere else.
    expect(desk.edits).toEqual([{ id: "m1", body: "Thursday works for me." }]);
    expect(host!.textContent).not.toContain("Drafted for you");
    expect(host!.querySelector(".bookit--prompt")).toBeNull();
  });
});

/*
 * The a11y audit (t6 #1, #4): pressing a chip disabled the very button that had focus, so focus
 * fell to <body>, and "Writing…" was plain button text no screen reader announced.
 */
describe("drafting keeps focus and says what it is doing", () => {
  it("holds focus on the reply's status while writing, then moves it to the reply", async () => {
    const pending = deferred();
    const desk = await mountDesk(() => pending.promise);
    await desk.show(draft);
    const accept = chip("Accept");
    accept.focus();
    await act(async () => accept.click());

    const status = host!.querySelector(".reply [role=status]") as HTMLElement;
    expect(status.getAttribute("aria-live")).toBe("polite");
    expect(status.textContent).toContain("Writing your reply");
    expect(document.activeElement).toBe(status);

    await act(async () => pending.resolve("Sounds good."));
    await desk.show(draft, "Sounds good.");
    expect(document.activeElement).toBe(host!.querySelector(".reply__body"));
    expect((host!.querySelector(".reply [role=status]") as HTMLElement).textContent).toContain("Drafted for you");
  });
});

describe("drafting over what he typed", () => {
  it("does not replace his words with a draft that lands after he has left the thread", async () => {
    // Nothing would be left on screen to Undo it with, so the late draft is dropped instead.
    const pending = deferred();
    const desk = await mountDesk(() => pending.promise);
    await desk.show(draft, "My own careful words.");
    await act(async () => chip("Accept").click());
    await desk.show(other);
    await act(async () => pending.resolve("Drafted."));
    expect(desk.edits).toEqual([]);
  });

  const replyButton = (label: string) =>
    [...host!.querySelectorAll(".reply button")].find((b) => b.textContent === label) as HTMLButtonElement | undefined;

  it("locks the reply while writing, and offers Undo back to his own words", async () => {
    const pending = deferred();
    const desk = await mountDesk(() => pending.promise);
    await desk.show(draft, "My own careful words.");
    await act(async () => chip("Decline").click());
    expect(textbox().disabled).toBe(true);

    await act(async () => pending.resolve("Thanks, but I can't make it."));
    await desk.show(draft, "Thanks, but I can't make it.");
    expect(textbox().disabled).toBe(false);

    await act(async () => replyButton("Undo")!.click());
    expect(desk.edits.at(-1)).toEqual({ id: "m1", body: "My own careful words." });
  });

  it("offers no Undo when there was nothing of his to restore", async () => {
    const desk = await mountDesk(async () => "Drafted.");
    await desk.show(draft, "");
    await act(async () => chip("Accept").click());
    await desk.show(draft, "Drafted.");
    expect(replyButton("Undo")).toBeUndefined();
  });
});

describe("a typed instruction", () => {
  it("goes out on the neutral intent, never as an 'accept'", async () => {
    const asked: [string?, string?][] = [];
    const desk = await mountDesk(async (_id, intent, instruction) => {
      asked.push([intent, instruction]);
      return "Drafted.";
    });
    await desk.show(draft);
    await act(async () => typeInto(instructionBox(), "Politely decline, I have a midterm"));
    const write = [...host!.querySelectorAll(".reply button")].find((b) => b.textContent === "Write it") as HTMLButtonElement;
    await act(async () => write.click());
    expect(asked).toEqual([["acknowledge", "Politely decline, I have a midterm"]]);
  });
});

describe("⌘↵ in the reply", () => {
  const press = (meta = true) =>
    textbox().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", metaKey: meta, bubbles: true }));

  it("opens Review & send — the review step, never a send", async () => {
    const desk = await mountDesk(async () => "x");
    await desk.show(draft, "Thursday works.");
    await act(async () => press());
    const dialog = document.querySelector("[role=dialog]");
    expect(dialog).not.toBeNull();
    expect((dialog!.querySelector("textarea") as HTMLTextAreaElement).value).toBe("Thursday works.");
  });

  it("does nothing with an empty reply, or on a plain Enter", async () => {
    const desk = await mountDesk(async () => "x");
    await desk.show(draft, "");
    await act(async () => press());
    expect(document.querySelector("[role=dialog]")).toBeNull();
    await desk.show(draft, "Hi");
    await act(async () => press(false));
    expect(document.querySelector("[role=dialog]")).toBeNull();
  });
});
