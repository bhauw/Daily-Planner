/*
 * The Tasks board, mounted whole against a fake engine, for the behaviour that
 * only exists at that level: where "Block time" opens, where focus goes, and
 * what an approval honestly says it did.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Api, PlannerEvent } from "../contract";
import TasksWorkspace from "./index";

const DAY = "2026-09-14";
const at = (m: number) =>
  `${DAY}T${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}:00-07:00`;

function ev(id: string, title: string, s: number, e: number): PlannerEvent {
  return { id, calendarId: "primary", title, category: "school", kind: "event", start: at(s), end: at(e), due: null, location: null } as PlannerEvent;
}

const schedule = [ev("lec", "ECONOMICS 250 Lecture", 9 * 60, 10 * 60 + 20), ev("focus", "Focus — Assignment 3", 11 * 60, 12 * 60)];

const fakeApi = {
  tasks: async () => ({
    lists: [
      { name: "School", items: [
        { id: "t2", title: "Midterm 2 review", category: "school", due: null, done: false },
        { id: "t3", title: "Submit lab report", category: "school", due: null, done: true },
      ] },
      { name: "Career", items: [
        { id: "t4", title: "Prep Example Corp STAR stories", category: "career", due: null, done: false },
      ] },
    ],
  }),
  preview: async () => ({ day: DAY, schedule, queue: [] }),
} as unknown as Api;

let roots: Root[] = [];
afterEach(() => {
  act(() => roots.forEach((r) => r.unmount()));
  roots = [];
  document.body.innerHTML = "";
});

async function mountBoard() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  roots.push(root);
  await act(async () => {
    root.render(createElement(TasksWorkspace, { api: fakeApi, day: DAY, detached: false }));
  });
  // useAsync resolves on a microtask; let it settle.
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
  return host;
}

function blockTimeFor(host: HTMLElement, title: string): HTMLButtonElement {
  const card = [...host.querySelectorAll(".task")].find((c) => c.textContent?.includes(title));
  const btn = [...(card?.querySelectorAll("button") ?? [])].find((b) => b.textContent?.includes("Block time"));
  if (!btn) throw new Error(`no Block time button for ${title}`);
  return btn as HTMLButtonElement;
}

describe("Block time (the keyboard path)", () => {
  it("opens on the first free gap, not on top of the 11:00 focus block", async () => {
    const host = await mountBoard();
    await act(async () => blockTimeFor(host, "Midterm 2 review").click());
    const starts = host.querySelector("form.compose select") as HTMLSelectElement;
    expect(starts.selectedOptions[0]?.textContent).toBe("12:00");
    expect(host.querySelector(".compose__warn")).toBeNull();
  });
});

async function capture(host: HTMLElement, text: string) {
  const input = host.querySelector(".capture__input") as HTMLInputElement;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, text);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => {
    (host.querySelector("form.capture__bar") as HTMLFormElement).requestSubmit();
  });
}

describe("a capture with no clear list", () => {
  it("asks for a list, and cannot be approved until one is picked", async () => {
    const host = await mountBoard();
    await capture(host, "Finish case comp deck");
    const card = host.querySelector(".capture__proposals .proposal") as HTMLElement;
    expect(card.textContent).toContain("No clear match — pick a list");
    const approve = [...card.querySelectorAll("button")].find((b) => b.textContent === "Approve")!;
    expect(approve.disabled).toBe(true);

    const pick = card.querySelector("select") as HTMLSelectElement;
    await act(async () => {
      pick.value = "Career";
      pick.dispatchEvent(new Event("change", { bubbles: true }));
    });
    expect(card.querySelector(".proposal__fact dd")?.textContent).toContain("Career");
    expect([...card.querySelectorAll("button")].find((b) => b.textContent === "Approve")!.disabled).toBe(false);
  });
});

// `.task--done { opacity: 0.6; }` used to fade the category tag and due-date text below 4.5:1
// (contrast.test.ts pins the token math; this pins that TaskCard actually stops handing the
// category ink to a done row's tag, since Tag sets its colour inline and a CSS rule can't
// override that).
describe("a done task's tag is muted, not just faded", () => {
  it("mutes the done task's tag to --text-2 instead of the category ink", async () => {
    const host = await mountBoard();
    const card = [...host.querySelectorAll(".task")].find((c) => c.textContent?.includes("Submit lab report"))!;
    expect(card.classList.contains("task--done")).toBe(true);
    const tag = card.querySelector(".tag") as HTMLElement;
    expect(tag.style.color).toBe("var(--text-2)");
  });

  it("keeps an open task's tag on its category ink", async () => {
    const host = await mountBoard();
    const card = [...host.querySelectorAll(".task")].find((c) => c.textContent?.includes("Midterm 2 review"))!;
    const tag = card.querySelector(".tag") as HTMLElement;
    expect(tag.style.color).not.toBe("var(--text-2)");
  });
});

// Tasks never rendered an <h1> — its outermost heading was ColumnHeader's <h3> ("Lists &
// focus blocks"), same defect as Home and Mail (audit finding #6).
describe("Tasks has a real page heading", () => {
  it("renders exactly one <h1>", async () => {
    const host = await mountBoard();
    expect(host.querySelectorAll("h1").length).toBe(1);
  });

  it("promotes the column header so the outline goes h1 -> h2, not h1 -> h3", async () => {
    const host = await mountBoard();
    const colhead = host.querySelector(".colhead__title")!;
    expect(colhead.tagName).toBe("H2");
  });
});

// `role="listitem"` on a <section> is invalid — <section> does not accept that role, so a
// screen reader may not announce the five lists as a list at all (audit finding #5). The board
// is a real <ul>/<li> instead; <section> keeps its native landmark semantics inside each <li>.
describe("list column markup", () => {
  it("is a real <ul>, never role=list on a <div>", async () => {
    const host = await mountBoard();
    const tasklists = host.querySelector("ul.tasklists");
    expect(tasklists).not.toBeNull();
    expect(tasklists?.tagName).toBe("UL");
    expect(host.querySelector('div.tasklists[role="list"]')).toBeNull();
  });

  it("never puts role=listitem on a <section>", async () => {
    const host = await mountBoard();
    const sections = host.querySelectorAll("section.tasklist");
    expect(sections.length).toBeGreaterThan(0);
    for (const section of sections) {
      expect(section.getAttribute("role")).toBeNull();
      expect(section.parentElement?.tagName).toBe("LI");
    }
  });
});

describe("Block time from the keyboard", () => {
  it("gives every Block time button its own name", async () => {
    const host = await mountBoard();
    const names = [...host.querySelectorAll("button")]
      .filter((b) => b.textContent?.includes("Block time"))
      .map((b) => b.getAttribute("aria-label"));
    expect(names).toEqual(["Block time for Midterm 2 review", "Block time for Prep Example Corp STAR stories"]);
  });

  it("moves focus into the form, and Esc cancels back to the button that opened it", async () => {
    const host = await mountBoard();
    const opener = host.querySelector('[aria-label="Block time for Midterm 2 review"]') as HTMLButtonElement;
    opener.focus();
    await act(async () => opener.click());
    const starts = host.querySelector("form.compose select") as HTMLSelectElement;
    expect(document.activeElement).toBe(starts);

    await act(async () => {
      starts.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(host.querySelector("form.compose")).toBeNull();
    expect(document.activeElement).toBe(opener);
  });
});

describe("approvals say honestly that nothing reached Google Tasks", () => {
  // The grant is tasks.readonly (ApprovedGoogleScopes.swift) and there is no task write route,
  // so an approval can only be kept locally. It used to vanish without a word.
  it("an approved move stays visible on the card, saying where and that it is local only", async () => {
    const host = await mountBoard();
    const card = () => [...host.querySelectorAll(".task")].find((c) => c.textContent?.includes("Midterm 2 review"))!;
    const select = card().querySelector("select") as HTMLSelectElement;
    await act(async () => {
      select.value = "Career";
      select.dispatchEvent(new Event("change", { bubbles: true }));
    });
    const approve = [...card().querySelectorAll("button")].find((b) => b.textContent === "Approve")!;
    await act(async () => approve.click());
    const text = card().textContent ?? "";
    expect(text).toContain("Approved — saved locally only; Google Tasks is read-only");
    expect(text).toContain("Career");
  });

  it("an approved capture says the same, and names its list", async () => {
    const host = await mountBoard();
    await capture(host, "Example Corp coffee chat tomorrow");
    const card = host.querySelector(".capture__proposals .proposal") as HTMLElement;
    const approve = [...card.querySelectorAll("button")].find((b) => b.textContent === "Approve")!;
    await act(async () => approve.click());
    const log = host.querySelector(".capture__log")?.textContent ?? "";
    expect(log).toContain("Approved — saved locally only; Google Tasks is read-only");
    expect(log).toContain("Career");
  });
});
