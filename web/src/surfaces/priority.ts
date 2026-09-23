/*
 * Priority model for the Focus surface.
 *
 * The engine's `PriorityEngine` orders the preview queue by category *name*,
 * alphabetically — career, commute, finance, other, personal, school, work.
 * That is stable and deterministic, but it is not a priority: it says nothing
 * about what to do next. Focus therefore ranks in the client, from the only
 * signals that actually carry urgency — time, and whether something is already
 * late — and every item carries the reason it landed where it did, so the
 * order is explainable rather than magic.
 *
 * Pure and deterministic: `now` is injected, never read from the clock in
 * here, so the same inputs always produce the same list and the tests can pin
 * every boundary.
 */

import type { Category, Draft, PlannerEvent, Preview, TaskItem, TaskList } from "../api/client";
import { colorForCategory, presentationFor } from "../lib/category";

/** What kind of thing an item is. Focus mixes all three. */
export type FocusKind = "event" | "task" | "reply";

/**
 * Urgency buckets, most urgent first. Exposed as numbers so a caller can group
 * and so the tests can assert a bucket rather than a list position.
 */
export const RANK = {
  overdue: 0,
  now: 1,
  next: 2,
  today: 3,
  later: 4,
  undated: 5,
} as const;

export type Rank = (typeof RANK)[keyof typeof RANK];

export const RANK_LABEL: Record<Rank, string> = {
  [RANK.overdue]: "Overdue",
  [RANK.now]: "Happening now",
  [RANK.next]: "Next up",
  [RANK.today]: "Later today",
  [RANK.later]: "This week",
  [RANK.undated]: "No date",
};

/**
 * The thing this row was built from, kept so a row can offer actions that fit
 * it. Ranking normalises an event, a task and a message into one shape; acting
 * on one needs the original back.
 */
export type FocusSource =
  | { kind: "event"; event: PlannerEvent }
  | { kind: "task"; task: TaskItem }
  | { kind: "reply"; draft: Draft };

export interface FocusItem {
  id: string;
  kind: FocusKind;
  source: FocusSource;
  title: string;
  category: Category;
  /** The instant this item hangs off: start for events, due for tasks. */
  at: string | null;
  /** End instant, events only — needed to know something is happening *now*. */
  until: string | null;
  rank: Rank;
  /** Why it ranks here. Rendered verbatim; never invented at display time. */
  reason: string;
  /** Secondary line: sender for a reply, list name for a task, location for an event. */
  detail: string | null;
  /**
   * The row's colour, resolved HERE rather than at render time.
   *
   * Focus used to re-derive it from `category` alone, which discarded the event's `kind` — so
   * the same event was one colour on Digest (which passes the whole event) and another on
   * Focus. An extracurricular event showed green in one place and magenta in the other, and
   * colour is the only pre-attentive channel these lists have. Resolving it where the full
   * source is still in hand makes that divergence unrepresentable.
   */
  colorVar: string;
}

/** Anything within this many minutes counts as "next up" rather than "later today". */
const NEXT_WINDOW_MINUTES = 120;

const MINUTE = 60_000;

function ms(iso: string | null): number | null {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? null : t;
}

/**
 * "in 25 min", "in 3 h", "2 days ago". Deliberately coarse: a focus surface
 * that counts seconds invites staring at it instead of working.
 */
export function relative(fromMs: number, toMs: number): string {
  const delta = toMs - fromMs;
  const ahead = delta >= 0;
  const minutes = Math.round(Math.abs(delta) / MINUTE);

  let value: string;
  if (minutes < 1) value = "now";
  else if (minutes < 60) value = `${minutes} min`;
  else if (minutes < 60 * 24) {
    const hours = Math.round(minutes / 60);
    value = `${hours} h`;
  } else {
    const days = Math.round(minutes / (60 * 24));
    value = days === 1 ? "1 day" : `${days} days`;
  }

  if (value === "now") return "now";
  return ahead ? `in ${value}` : `${value} ago`;
}

/** True when `t` falls on the same Vancouver day as `nowMs`. */
function sameDay(t: number, nowMs: number, zone: string): boolean {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: zone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(new Date(t)) === fmt.format(new Date(nowMs));
}

const ZONE = "America/Vancouver";

interface Placement {
  rank: Rank;
  reason: string;
}

/**
 * Where a single dated thing belongs. `until` is only meaningful for events:
 * a task has a deadline, not a duration, so it can never be "happening now".
 */
function placeDated(
  atMs: number | null,
  untilMs: number | null,
  nowMs: number,
  verb: string,
  /** False for plain events: only something with a deadline can be late. */
  canBeLate = true,
): Placement {
  if (atMs === null) {
    return { rank: RANK.undated, reason: "no date" };
  }

  // In progress beats everything except being late: it is what you are already doing.
  if (untilMs !== null && atMs <= nowMs && nowMs < untilMs) {
    return { rank: RANK.now, reason: `until ${relative(nowMs, untilMs).replace(/^in /, "")}` };
  }

  if (atMs < nowMs) {
    // An event whose end has passed is simply done — only deadlines go overdue.
    if (untilMs !== null) {
      return { rank: RANK.today, reason: "finished" };
    }
    // A point-in-time event with no end ("review posted") is behind you, not owed.
    if (!canBeLate) {
      return { rank: RANK.today, reason: `started ${relative(nowMs, atMs)}` };
    }
    return { rank: RANK.overdue, reason: `${verb} ${relative(nowMs, atMs)}` };
  }

  const minutesAway = (atMs - nowMs) / MINUTE;
  if (minutesAway <= NEXT_WINDOW_MINUTES) {
    return { rank: RANK.next, reason: `${verb} ${relative(nowMs, atMs)}` };
  }
  if (sameDay(atMs, nowMs, ZONE)) {
    return { rank: RANK.today, reason: `${verb} ${relative(nowMs, atMs)}` };
  }
  return { rank: RANK.later, reason: `${verb} ${relative(nowMs, atMs)}` };
}

function eventItem(event: PlannerEvent, nowMs: number): FocusItem {
  // A deadline's moment is its due instant; a normal event's is when it starts.
  //
  // Only an event that actually carries `due` is a deadline. A movable work block ("Focus —
  // Assignment 3") is kind "deadline" too, but with no due and a real end: reading its start as
  // a due instant made it go "overdue" the moment it began and take the lead card with "due 6 h
  // ago" on a block that had simply ended. Without a due it is timed like any other event.
  //
  // The reverse holds too: a Priority-queue item like "interview time" is kind "event" with a
  // start that is only when it was noticed and a real due. The due is the moment that matters,
  // so anything carrying one hangs off it.
  const isDeadline = Boolean(event.due);
  const atIso = isDeadline ? event.due! : event.start;
  const untilIso = isDeadline ? null : event.end;
  const placement = isDeadline
    ? placeDated(ms(atIso), null, nowMs, "due")
    : placeDated(ms(atIso), ms(untilIso), nowMs, "starts", false);

  return {
    id: event.id,
    kind: "event",
    source: { kind: "event", event },
    title: event.title,
    category: event.category,
    at: atIso,
    until: untilIso,
    rank: placement.rank,
    reason: placement.reason,
    detail: event.location,
    // The whole event, so `kind` survives — this is the case that was wrong.
    colorVar: presentationFor(event).colorVar,
  };
}

function taskItems(lists: TaskList[], nowMs: number): FocusItem[] {
  const out: FocusItem[] = [];
  for (const list of lists) {
    for (const item of list.items) {
      if (item.done) continue; // a finished task is not something to focus on
      const placement = placeDated(ms(item.due), null, nowMs, "due");
      out.push({
        id: item.id,
        kind: "task",
        source: { kind: "task", task: item },
        title: item.title,
        category: item.category,
        at: item.due,
        until: null,
        rank: placement.rank,
        reason: placement.reason,
        detail: list.name,
        colorVar: colorForCategory(item.category),
      });
    }
  }
  return out;
}

/**
 * Mail that is waiting on you. A message has no deadline, so it never claims to
 * be overdue — it sits in `undated` unless it arrived today, or unless the
 * engine's triage banded it urgent.
 *
 * The band is the engine's own read of the message (a security warning, an
 * interview), and Digest already trusts it for "Read first". Ignoring it here
 * put the same security alert under "No date", after Groceries — one message,
 * two contradictory ranks. Urgent mail goes to Next up, and the engine's `why`
 * is the reason, so the row says the phrase that put it there.
 */
function replyItems(drafts: Draft[], nowMs: number): FocusItem[] {
  return drafts
    .filter((d) => d.kind === "reply")
    .map((draft) => {
      const received = ms(draft.receivedAt ?? null);
      const isToday = received !== null && sameDay(received, nowMs, ZONE);
      const urgent = draft.band === "urgent";
      const arrived = received === null ? "waiting" : `arrived ${relative(nowMs, received)}`;
      return {
        id: draft.id,
        kind: "reply" as const,
        source: { kind: "reply" as const, draft },
        title: draft.title,
        category: draft.category ?? "other",
        at: draft.receivedAt ?? null,
        until: null,
        rank: urgent ? RANK.next : isToday ? RANK.today : RANK.undated,
        reason: urgent ? (draft.why ?? arrived) : arrived,
        detail: draft.sender ?? null,
        colorVar: colorForCategory(draft.category ?? "other"),
      };
    });
}

function compare(a: FocusItem, b: FocusItem): number {
  if (a.rank !== b.rank) return a.rank - b.rank;

  const at = ms(a.at);
  const bt = ms(b.at);
  if (at !== bt) {
    if (at === null) return 1; // undated sinks within its bucket
    if (bt === null) return -1;
    // Earliest first in every bucket. For overdue that is also worst-first: the oldest
    // missed instant is the thing you are latest on.
    return at - bt;
  }

  if (a.title !== b.title) return a.title < b.title ? -1 : 1;
  return a.id < b.id ? -1 : 1; // total order, so the list never reshuffles on reload
}

/**
 * Every event Focus should rank: the Priority queue and the schedule, each once.
 *
 * They were assumed to be the same events in two orders, so only the schedule was ranked. They
 * are not — the queue carries its own items (an interview-time ask, a club sign-up) — and Focus,
 * the surface that claims to be "what to do next", never listed them. Deduplicated by id so an
 * event on both is ranked once; the schedule's copy wins, since it carries the real end.
 */
export function focusEvents(preview: Preview): PlannerEvent[] {
  const byId = new Map<string, PlannerEvent>();
  for (const event of preview.queue) byId.set(event.id, event);
  for (const event of preview.schedule) byId.set(event.id, event);
  return [...byId.values()];
}

export interface FocusInput {
  events: PlannerEvent[];
  lists: TaskList[];
  drafts: Draft[];
  /** Injected so the ranking is testable and never depends on the wall clock. */
  now: Date;
}

/** Everything worth doing, most urgent first. */
export function rankFocus({ events, lists, drafts, now }: FocusInput): FocusItem[] {
  const nowMs = now.getTime();
  return [
    ...events.map((e) => eventItem(e, nowMs)),
    ...taskItems(lists, nowMs),
    ...replyItems(drafts, nowMs),
  ].sort(compare);
}

/** The same list, grouped into its buckets with empty buckets dropped. */
export function groupByRank(items: FocusItem[]): { rank: Rank; label: string; items: FocusItem[] }[] {
  const order: Rank[] = [RANK.overdue, RANK.now, RANK.next, RANK.today, RANK.later, RANK.undated];
  return order
    .map((rank) => ({ rank, label: RANK_LABEL[rank], items: items.filter((i) => i.rank === rank) }))
    .filter((group) => group.items.length > 0);
}
