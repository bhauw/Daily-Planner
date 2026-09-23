/*
 * Focus ranking tests.
 *
 * Focus tells Braxton what to do next. If the order is wrong he does the wrong
 * thing, so every bucket boundary is pinned here rather than eyeballed in the
 * UI. `now` is injected, so these are exact — no tolerance windows, no flake.
 */

import { describe, expect, it } from "vitest";
import type { Draft, PlannerEvent, TaskList } from "../api/client";
import { RANK, focusEvents, groupByRank, rankFocus, relative } from "./priority";
import { presentationFor } from "../lib/category";

// A fixed Vancouver afternoon. Everything below is expressed relative to it.
const NOW = new Date("2026-09-16T12:00:00-07:00");

function at(offsetMinutes: number): string {
  return new Date(NOW.getTime() + offsetMinutes * 60_000).toISOString();
}

function event(over: Partial<PlannerEvent> & Pick<PlannerEvent, "id">): PlannerEvent {
  return {
    title: "Event",
    calendarId: "primary",
    category: "school",
    kind: "event",
    start: at(0),
    end: null,
    due: null,
    location: null,
    ...over,
  };
}

function list(items: TaskList["items"]): TaskList[] {
  return [{ name: "Inbox", items }];
}

function empty() {
  return { events: [], lists: [], drafts: [], now: NOW };
}

describe("rankFocus", () => {
  it("puts an event in progress above one that has not started", () => {
    const items = rankFocus({
      ...empty(),
      events: [
        event({ id: "later", start: at(30) }),
        event({ id: "running", start: at(-15), end: at(45) }),
      ],
    });

    expect(items.map((i) => i.id)).toEqual(["running", "later"]);
    expect(items[0].rank).toBe(RANK.now);
    expect(items[1].rank).toBe(RANK.next);
  });

  it("treats a missed deadline as overdue but a finished event as done", () => {
    const items = rankFocus({
      ...empty(),
      events: [
        event({ id: "deadline", kind: "deadline", due: at(-60), start: at(-60) }),
        event({ id: "finished", start: at(-120), end: at(-60) }),
      ],
    });

    const byId = Object.fromEntries(items.map((i) => [i.id, i]));
    // A deadline you blew past is the most urgent thing there is.
    expect(byId.deadline.rank).toBe(RANK.overdue);
    expect(byId.deadline.reason).toBe("due 1 h ago");
    // An event that simply ended is not a thing you owe anyone.
    expect(byId.finished.rank).toBe(RANK.today);
    expect(byId.finished.reason).toBe("finished");
  });

  /*
   * A movable work block ("Focus — Assignment 3") is kind "deadline" with no `due` and a real
   * end. It used to be read as a point-in-time deadline at its start, so once it began it went
   * overdue and took the lead card — "due 6 h ago" on a block that had simply ended.
   */
  it("treats a deadline-kind block with no due as an ordinary timed event", () => {
    const items = rankFocus({
      ...empty(),
      events: [
        event({ id: "ended", kind: "deadline", due: null, start: at(-330), end: at(-270) }),
        event({ id: "running", kind: "deadline", due: null, start: at(-30), end: at(30) }),
      ],
    });

    const byId = Object.fromEntries(items.map((i) => [i.id, i]));
    expect(byId.ended.rank).toBe(RANK.today);
    expect(byId.ended.reason).toBe("finished");
    expect(byId.ended.until).toBe(at(-270));
    expect(byId.running.rank).toBe(RANK.now);
    expect(items.every((i) => i.rank !== RANK.overdue)).toBe(true);
  });

  // The Priority queue carries items like "interview time" — kind "event", a start that is
  // just when it was noticed, and a real `due`. The due is the moment that matters.
  it("hangs any event that carries a due off the due, whatever its kind", () => {
    const [item] = rankFocus({
      ...empty(),
      events: [event({ id: "q1", kind: "event", start: at(-60), end: null, due: at(360) })],
    });

    expect(item.rank).toBe(RANK.today);
    expect(item.reason).toBe("due in 6 h");
    expect(item.at).toBe(at(360));
  });

  // Only a deadline can be late. A point-in-time event that has passed is behind you, not owed.
  it("never calls a past point-in-time event overdue", () => {
    const [item] = rankFocus({
      ...empty(),
      events: [event({ id: "posted", start: at(-15), end: null, due: null })],
    });

    expect(item.rank).toBe(RANK.today);
    expect(item.reason).toBe("started 15 min ago");
  });

  it("splits the next two hours from the rest of the day", () => {
    const items = rankFocus({
      ...empty(),
      events: [
        event({ id: "inside", start: at(119) }),
        event({ id: "outside", start: at(121) }),
      ],
    });

    const byId = Object.fromEntries(items.map((i) => [i.id, i]));
    expect(byId.inside.rank).toBe(RANK.next);
    expect(byId.outside.rank).toBe(RANK.today);
  });

  it("separates later today from later in the week", () => {
    const items = rankFocus({
      ...empty(),
      // 10 h ahead is 22:00 the same Vancouver day; 20 h ahead is the next morning.
      events: [event({ id: "tonight", start: at(60 * 10) }), event({ id: "tomorrow", start: at(60 * 20) })],
    });

    const byId = Object.fromEntries(items.map((i) => [i.id, i]));
    expect(byId.tonight.rank).toBe(RANK.today);
    expect(byId.tomorrow.rank).toBe(RANK.later);
  });

  it("ranks an overdue task above everything and says how late it is", () => {
    const items = rankFocus({
      ...empty(),
      events: [event({ id: "soon", start: at(10) })],
      lists: list([{ id: "late", title: "Assignment 3", category: "school", due: at(-60 * 24 * 2), done: false }]),
    });

    expect(items[0].id).toBe("late");
    expect(items[0].rank).toBe(RANK.overdue);
    expect(items[0].reason).toBe("due 2 days ago");
  });

  it("ignores finished tasks", () => {
    const items = rankFocus({
      ...empty(),
      lists: list([
        { id: "done", title: "Done", category: "school", due: at(-60), done: true },
        { id: "open", title: "Open", category: "school", due: at(-60), done: false },
      ]),
    });

    expect(items.map((i) => i.id)).toEqual(["open"]);
  });

  it("never claims mail is overdue, because a message has no deadline", () => {
    const drafts: Draft[] = [
      { id: "old", title: "Re: co-op", summary: "", kind: "reply", sender: "a@b.c", receivedAt: at(-60 * 24 * 3) },
      { id: "new", title: "Re: today", summary: "", kind: "reply", sender: "d@e.f", receivedAt: at(-30) },
    ];
    const items = rankFocus({ ...empty(), drafts });
    const byId = Object.fromEntries(items.map((i) => [i.id, i]));

    expect(byId.old.rank).toBe(RANK.undated);
    expect(byId.new.rank).toBe(RANK.today);
    expect(items.every((i) => i.rank !== RANK.overdue)).toBe(true);
  });

  /*
   * The engine's triage band is what Digest trusts to put a security alert and an interview in
   * "Read first". Focus threw it away and ranked both under "No date", after Groceries.
   */
  it("lifts mail the engine banded urgent to Next up, with the engine's reason", () => {
    const drafts: Draft[] = [
      {
        id: "sec", title: "Security alert", summary: "", kind: "reply", sender: "no-reply@x.com",
        receivedAt: null, band: "urgent", reason: "security", why: "Security warning — \"new sign in\"",
      },
      { id: "plain", title: "Statement", summary: "", kind: "reply", receivedAt: null, band: "ordinary", why: "Finance" },
    ];
    const items = rankFocus({
      ...empty(),
      drafts,
      lists: list([{ id: "g", title: "Groceries", category: "personal", due: null, done: false }]),
    });
    const byId = Object.fromEntries(items.map((i) => [i.id, i]));

    expect(byId.sec.rank).toBe(RANK.next);
    expect(byId.sec.reason).toBe("Security warning — \"new sign in\"");
    expect(byId.plain.rank).toBe(RANK.undated);
    expect(items[0].id).toBe("sec");
  });

  it("only surfaces mail that is actually a reply", () => {
    const drafts: Draft[] = [
      { id: "reply", title: "Needs an answer", summary: "", kind: "reply", receivedAt: at(-30) },
      { id: "ad", title: "50% off", summary: "", kind: "bundle", receivedAt: at(-30) },
    ];
    expect(rankFocus({ ...empty(), drafts }).map((i) => i.id)).toEqual(["reply"]);
  });

  it("is a total order, so the same data never reshuffles between reloads", () => {
    const events = [
      event({ id: "b", title: "Same", start: at(30) }),
      event({ id: "a", title: "Same", start: at(30) }),
    ];
    const first = rankFocus({ ...empty(), events }).map((i) => i.id);
    const second = rankFocus({ ...empty(), events: [...events].reverse() }).map((i) => i.id);

    expect(first).toEqual(["a", "b"]);
    expect(second).toEqual(first);
  });

  it("groups into buckets and drops the empty ones", () => {
    const groups = groupByRank(
      rankFocus({
        ...empty(),
        events: [event({ id: "soon", start: at(10) })],
        lists: list([{ id: "late", title: "Late", category: "school", due: at(-60), done: false }]),
      }),
    );

    expect(groups.map((g) => g.label)).toEqual(["Overdue", "Next up"]);
  });
});

/*
 * Focus ranked `preview.schedule` alone, on the belief that the queue was the same events in
 * another order. It is not: the Priority queue carries its own items (an interview-time ask, a
 * sign-up), and Focus — "what to do next" — never listed them.
 */
describe("focusEvents", () => {
  it("ranks the queue and the schedule together, each event once", () => {
    const shared = event({ id: "s1", start: at(30) });
    const merged = focusEvents({
      queue: [event({ id: "q1", start: at(60) }), shared],
      schedule: [shared, event({ id: "s2", start: at(90) })],
      day: "2026-09-16",
    });

    expect(merged.map((e) => e.id).sort()).toEqual(["q1", "s1", "s2"]);
  });
});

describe("relative", () => {
  const base = NOW.getTime();

  it("reads forwards and backwards without false precision", () => {
    expect(relative(base, base + 25 * 60_000)).toBe("in 25 min");
    expect(relative(base, base - 25 * 60_000)).toBe("25 min ago");
    expect(relative(base, base + 3 * 60 * 60_000)).toBe("in 3 h");
    expect(relative(base, base - 48 * 60 * 60_000)).toBe("2 days ago");
    expect(relative(base, base - 24 * 60 * 60_000)).toBe("1 day ago");
  });

  it("says 'now' rather than 'in 0 min'", () => {
    expect(relative(base, base)).toBe("now");
    expect(relative(base, base + 20_000)).toBe("now");
  });
});

/*
 * Colour is the only pre-attentive channel these dense dark lists have, so the same event
 * must not be one colour on Digest and another on Focus. It was: Focus re-derived colour from
 * `category` alone via `colorForCategory`, which hardcodes `kind: "event"`, so an
 * extracurricular event read green on Digest and magenta on Focus. These pin the agreement.
 */
describe("row colour", () => {
  it("agrees with presentationFor for an extracurricular event", () => {
    const ev = event({ id: "club", category: "personal", kind: "extracurricular" });
    const [item] = rankFocus({ ...empty(), events: [ev] });

    expect(item.colorVar).toBe(presentationFor(ev).colorVar);
    expect(item.colorVar).toBe("var(--cat-extracurricular)");
  });

  it("agrees with presentationFor for a school deadline", () => {
    const ev = event({ id: "a3", category: "school", kind: "deadline", due: at(60) });
    const [item] = rankFocus({ ...empty(), events: [ev] });

    expect(item.colorVar).toBe(presentationFor(ev).colorVar);
    expect(item.colorVar).toBe("var(--cat-deadline)");
  });

  it("never disagrees with presentationFor across every event kind", () => {
    const kinds: PlannerEvent["kind"][] = ["event", "deadline", "extracurricular"];
    const categories: PlannerEvent["category"][] = [
      "school", "career", "finance", "personal", "commute", "work", "other",
    ];
    for (const kind of kinds) {
      for (const category of categories) {
        const ev = event({ id: `${kind}-${category}`, kind, category, due: at(60) });
        const [item] = rankFocus({ ...empty(), events: [ev] });
        expect(item.colorVar, `${kind}/${category}`).toBe(presentationFor(ev).colorVar);
      }
    }
  });

  it("falls back to the category for a task, which has no event kind", () => {
    const [item] = rankFocus({
      ...empty(),
      lists: list([{ id: "t", title: "Groceries", category: "personal", due: at(60), done: false }]),
    });

    expect(item.colorVar).toBe("var(--cat-personal)");
  });
});
