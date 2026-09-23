/*
 * The pure half of the prep card: detection, thread matching, and the 48-hour flip.
 *
 * These are the four things P3's spec calls out by name — detection, thread matching, the
 * 48h flip, and (in PrepCard.test.tsx) that nothing sends without the review step. Kept in
 * one file with no React and no fetch, so every case is a plain input/output assertion.
 */

import { describe, expect, it } from "vitest";
import type { Draft, PlannerEvent, TaskItem } from "../api/client";
import {
  detectPrep,
  eventTokens,
  FOLLOW_UP_WINDOW_MS,
  firmsIn,
  hostMatches,
  matchTasks,
  matchThreads,
  normalize,
  prepPhase,
  senderHost,
  thankYouInstruction,
  thankYousDue,
  thankYouSubject,
} from "./match";

function event(over: Partial<PlannerEvent> & Pick<PlannerEvent, "id" | "title">): PlannerEvent {
  return {
    category: "other",
    kind: "event",
    start: "2026-09-21T13:00:00-07:00",
    end: "2026-09-21T13:45:00-07:00",
    due: null,
    location: null,
    calendarId: "primary",
    ...over,
  };
}

function draft(over: Partial<Draft> & Pick<Draft, "id">): Draft {
  return { title: "Subject", summary: "", kind: "reply", ...over } as Draft;
}

function task(over: Partial<TaskItem> & Pick<TaskItem, "id" | "title">): TaskItem {
  return { category: "career", due: null, done: false, ...over };
}

// ---- Detection ----------------------------------------------------------------------------

describe("detectPrep", () => {
  it("qualifies a career-coloured event named only by kind — no firm needed", () => {
    const e = event({ id: "1", title: "Coffee chat", category: "career" });
    const prep = detectPrep(e);
    expect(prep?.kind).toBe("coffee chat");
    expect(prep?.firms).toEqual([]);
  });

  it("qualifies a career-coloured event named only by firm — no kind word needed", () => {
    const e = event({ id: "2", title: "Example Corp", category: "career" });
    const prep = detectPrep(e);
    expect(prep?.firms.map((f) => f.id)).toEqual(["example-corp"]);
    // No kind phrase in the title: falls back to the default.
    expect(prep?.kind).toBe("coffee chat");
  });

  it("qualifies an uncoloured event only when it names BOTH the conversation and a firm", () => {
    const named = event({ id: "3", title: "Interview — Example Corp Audit Co-op", category: "other" });
    expect(detectPrep(named)?.label).toBe("Example Corp interview");

    // Names the firm but not the kind of conversation: does not qualify off-colour.
    const firmOnly = event({ id: "4", title: "Example Corp", category: "other" });
    expect(detectPrep(firmOnly)).toBeNull();

    // Names the kind but not a firm: does not qualify off-colour either.
    const kindOnly = event({ id: "5", title: "Coffee chat", category: "other" });
    expect(detectPrep(kindOnly)).toBeNull();
  });

  it("does not treat a personal coffee as a prep card", () => {
    const e = event({ id: "6", title: "Coffee with Sam", category: "personal" });
    expect(detectPrep(e)).toBeNull();
  });

  it("does not treat networking off-colour as a prep card even with a firm named", () => {
    const e = event({ id: "7", title: "Example Consulting info session", category: "other" });
    expect(detectPrep(e)).toBeNull();
  });

  it("does treat career-coloured networking as a prep card", () => {
    const e = event({ id: "8", title: "Campus mixer — Example Consulting", category: "career" });
    expect(detectPrep(e)?.kind).toBe("networking");
  });

  it("skips anything that is not a calendar event", () => {
    const deadline = event({ id: "9", title: "Interview — Example Corp", kind: "deadline", category: "career" });
    expect(detectPrep(deadline)).toBeNull();
    const extracurricular = event({ id: "10", title: "Interview — Example Corp", kind: "extracurricular", category: "career" });
    expect(detectPrep(extracurricular)).toBeNull();
  });

  it("skips an event with an unparseable start", () => {
    const e = event({ id: "11", title: "Coffee chat", category: "career", start: "not-a-date" });
    expect(detectPrep(e)).toBeNull();
  });

  it("word-bounds firm matching: EY does not match inside other words", () => {
    // "hey", "key" and "survey" all contain the letters e-y; none of them names the firm EY.
    expect(firmsIn("Hey — quick survey before the key handoff")).toEqual([]);
    expect(firmsIn("Interview — EY")).toHaveLength(1);
  });

  it("falls back to the title's distinctive words when no known firm is named", () => {
    expect(eventTokens("Coffee chat — Acme Advisory")).toContain("acme");
    expect(eventTokens("Coffee chat — Acme Advisory")).not.toContain("coffee");
    expect(eventTokens("Coffee chat — Acme Advisory")).not.toContain("advisory"); // generic word
  });
});

// ---- Thread matching ------------------------------------------------------------------------

describe("matchThreads", () => {
  const consultingPrep = detectPrep(event({ id: "e1", title: "Example Consulting coffee chat", category: "career" }))!;

  it("ranks a sender at the firm's host above a subject that merely names the firm", () => {
    const hostSender = draft({ id: "a", title: "Let's grab coffee", sender: "jordan.lee@example.test" });
    const subjectOnly = draft({ id: "b", title: "Re: your Example Consulting application", sender: "noreply@example.com" });
    const matches = matchThreads(consultingPrep, [subjectOnly, hostSender]);
    expect(matches.map((m) => m.draft.id)).toEqual(["a", "b"]);
    expect(matches[0].reason).toContain("sender is @example.test");
  });

  it("matches a subdomain of the firm's host, not an unrelated domain that merely contains it", () => {
    expect(hostMatches("hr@mail.example.test", "example.test")).toBe(true);
    expect(hostMatches("x@notexample.test", "example.test")).toBe(false);
    expect(hostMatches("x@example.test.example.com", "example.test")).toBe(false);
    expect(senderHost("Jordan Lee <jordan@example.test>")).toBe("example.test");
  });

  it("never proposes a thread with no sender — a synthetic bundle row has nobody to answer", () => {
    const bundle = draft({ id: "bundle", title: "Example Consulting coffee chat", kind: "bundle" });
    expect(matchThreads(consultingPrep, [bundle])).toEqual([]);
  });

  it("finds a thread by a guessed token when no known firm is named", () => {
    const acmePrep = detectPrep(event({ id: "e2", title: "Coffee chat — Acme Advisory", category: "career" }))!;
    const fromAcme = draft({ id: "c", title: "Following up from the mixer", sender: "sam@acme.com" });
    expect(matchThreads(acmePrep, [fromAcme])[0]?.draft.id).toBe("c");
  });

  it("caps at MAX_THREADS even when more match", () => {
    const drafts = ["x1", "x2", "x3", "x4", "x5"].map((id) =>
      draft({ id, title: "Example Consulting", sender: `${id}@example.test` }),
    );
    expect(matchThreads(consultingPrep, drafts)).toHaveLength(3);
  });

  it("shows no matches for unrelated mail", () => {
    const unrelated = draft({ id: "z", title: "Your statement is ready", sender: "alerts@example-bank.com" });
    expect(matchThreads(consultingPrep, [unrelated])).toEqual([]);
  });
});

describe("matchTasks", () => {
  it("finds open tasks that share the event's firm token, and skips done ones", () => {
    const prep = detectPrep(event({ id: "e3", title: "Example Corp interview", category: "career" }))!;
    const tasks = [
      task({ id: "t1", title: "Prep Example Corp STAR stories" }),
      task({ id: "t2", title: "Prep Example Corp STAR stories", done: true }),
      task({ id: "t3", title: "Buy groceries" }),
    ];
    expect(matchTasks(prep, tasks).map((t) => t.id)).toEqual(["t1"]);
  });

  it("returns nothing when the event has no firm and no usable tokens", () => {
    const prep = detectPrep(event({ id: "e4", title: "Coffee chat", category: "career" }))!;
    expect(matchTasks(prep, [task({ id: "t4", title: "Prep for it" })])).toEqual([]);
  });
});

// ---- The 48-hour flip -----------------------------------------------------------------------

describe("prepPhase", () => {
  const start = new Date("2026-09-21T13:00:00-07:00");
  const end = new Date("2026-09-21T13:45:00-07:00");
  const e = event({ id: "p", title: "Example Corp interview", category: "career", start: start.toISOString(), end: end.toISOString() });

  it("is upcoming before it starts, and live once it has started", () => {
    expect(prepPhase(e, new Date(start.getTime() - 1))).toBe("upcoming");
    expect(prepPhase(e, start)).toBe("live");
  });

  it("is still live at the exact end minute — not follow-through yet", () => {
    expect(prepPhase(e, end)).toBe("live");
  });

  it("flips to followUp the instant after it ends", () => {
    expect(prepPhase(e, new Date(end.getTime() + 1))).toBe("followUp");
  });

  it("stays followUp right up to, but not including, the 48-hour mark", () => {
    expect(prepPhase(e, new Date(end.getTime() + FOLLOW_UP_WINDOW_MS - 1))).toBe("followUp");
  });

  it("closes at exactly 48 hours — the window is half-open", () => {
    expect(prepPhase(e, new Date(end.getTime() + FOLLOW_UP_WINDOW_MS))).toBe("past");
  });

  it("treats an event with no end as 45 minutes long, same as scheduling's default", () => {
    const noEnd = event({ id: "q", title: "Coffee chat", category: "career", start: start.toISOString(), end: null });
    expect(prepPhase(noEnd, new Date(start.getTime() + 44 * 60_000))).toBe("live");
    expect(prepPhase(noEnd, new Date(start.getTime() + 46 * 60_000))).toBe("followUp");
  });
});

describe("thankYousDue", () => {
  const now = new Date("2026-09-21T15:00:00-07:00"); // 1h15m after the chat below ends
  const chat = event({
    id: "due1",
    title: "Example Consulting coffee chat",
    category: "career",
    start: "2026-09-21T13:00:00-07:00",
    end: "2026-09-21T13:45:00-07:00",
  });
  const oldChat = event({
    id: "due2",
    title: "PwC coffee chat",
    category: "career",
    start: "2026-09-15T13:00:00-07:00",
    end: "2026-09-15T13:45:00-07:00",
  });
  const notPrep = event({ id: "lecture", title: "ECONOMICS 250 lecture", category: "school" });

  it("surfaces only career conversations ended within the last 48 hours", () => {
    const due = thankYousDue([chat, oldChat, notPrep], now);
    expect(due.map((d) => d.prep.event.id)).toEqual(["due1"]);
  });

  it("de-duplicates the same event id appearing twice (today's schedule union the week)", () => {
    const due = thankYousDue([chat, chat], now);
    expect(due).toHaveLength(1);
  });

  it("drops an event once it has been thanked this session", () => {
    const due = thankYousDue([chat], now, new Set(["due1"]));
    expect(due).toEqual([]);
  });

  it("orders most recently ended first", () => {
    const recent = event({
      id: "due3",
      title: "EY coffee chat",
      category: "career",
      start: "2026-09-21T14:00:00-07:00",
      end: "2026-09-21T14:30:00-07:00",
    });
    const due = thankYousDue([chat, recent], now);
    expect(due.map((d) => d.prep.event.id)).toEqual(["due3", "due1"]);
  });
});

// ---- What drafting may say -------------------------------------------------------------------

describe("thankYouInstruction", () => {
  it("never carries the calendar's title, location or firm name — only a relative day", () => {
    const now = new Date("2026-09-21T15:00:00-07:00");
    const e = event({
      id: "priv",
      title: "Interview — Example Corp Audit Co-op, downtown office",
      category: "career",
      location: "Example Corp, 939 Granville St",
      start: "2026-09-21T13:00:00-07:00",
      end: "2026-09-21T13:45:00-07:00",
    });
    const instruction = thankYouInstruction(e, now);
    expect(instruction).not.toContain("Example Corp");
    expect(instruction).not.toContain("Granville");
    expect(instruction).not.toContain("Interview");
    expect(instruction).toContain("today's conversation");
  });

  it("appends only the topic the user typed, trimmed to the byte cap", () => {
    const now = new Date("2026-09-21T15:00:00-07:00");
    const e = event({ id: "topic", title: "Coffee chat", category: "career", start: "2026-09-21T13:00:00-07:00", end: "2026-09-21T13:45:00-07:00" });
    const instruction = thankYouInstruction(e, now, "their move from audit into advisory");
    expect(instruction).toContain("their move from audit into advisory");
  });
});

describe("thankYouSubject", () => {
  it("names the firm when one is known, and falls back to the event title otherwise", () => {
    const withFirm = detectPrep(event({ id: "s1", title: "Example Consulting coffee chat", category: "career" }))!;
    expect(thankYouSubject(withFirm)).toBe("Thank you — Example Consulting coffee chat");

    const withoutFirm = detectPrep(event({ id: "s2", title: "Coffee chat with the team", category: "career" }))!;
    expect(thankYouSubject(withoutFirm)).toBe("Thank you — Coffee chat with the team");
  });
});

describe("normalize", () => {
  it("keeps & and folds every other punctuation run to a single boundary space", () => {
    expect(normalize("Ernst & Young — 2nd round!")).toBe(" ernst & young 2nd round ");
  });
});
