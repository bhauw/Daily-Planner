/*
 * Plan my day — the arithmetic behind "does today fit?".
 *
 * The morning ritual is three questions, and this module answers the two that are maths:
 * how much free time is there, and where would the picked work actually go. The third —
 * what matters today — is his call, made on screen.
 *
 * It deliberately builds on the gap model the Tasks dayline already uses
 * (`../../workspaces/tasks/insertion.ts`) rather than inventing a second one. Two
 * models of "free time" would eventually disagree about the same afternoon, and the
 * surface that was wrong would be the one he trusted.
 *
 * Decisions worth stating:
 *
 *  - Free time is only the gaps a block can actually use. A 10-minute sliver between two
 *    classes is not "free" in any sense that matters for planning, so gaps under
 *    `MIN_BLOCK_MIN` are left out of the total. Counting them would make the meter
 *    promise room the placer can never hand out.
 *  - A deadline with no end is not busy time. "Assignment due 14:00" is a moment, not an
 *    hour of the day; `spansFor` would give it a 15-minute footprint, which would cut a
 *    gap in two for no reason. Everything else on the day — classes, shifts, commutes,
 *    existing focus blocks — is an obstacle and is never touched.
 *  - Placement is first-fit in pick order. The order he picked in is the order he cares
 *    about, so the first pick gets the earliest room it fits in. A block is never split
 *    across a gap: half a focus block before a lecture and half after is two interrupted
 *    sessions, not one.
 *  - What does not fit is reported, not squeezed. Shrinking or dropping is his decision;
 *    silently trimming a 90-minute block to 40 would be the app deciding his day.
 *
 * Pure: `now` is injected, nothing here reads the clock or writes anywhere.
 */

import type { Category, CreateEventRequest, PlannerEvent, TaskList } from "../../api/client";
import { fromLocalInput } from "../../compose/datetime";
import { dayKey, minutesOfDay } from "../../workspaces/calendar/tz";
import { MIN_BLOCK_MIN, clock, gapFits, gapsFor, type Gap } from "../../workspaces/tasks/insertion";
import { RANK, rankFocus } from "../priority";

/** The sizes a pick can take. Coarse on purpose: estimating to the minute is false precision. */
export const SIZES = [15, 30, 60, 90] as const;
/** What a pick starts at — a focus block's natural length. */
export const DEFAULT_SIZE = 60;

/**
 * Working hours. The same 09:00–21:00 window the Today dayline and the Tasks dayline draw,
 * so "free" means the same thing on every surface.
 */
export const WORK_START = 9 * 60;
export const WORK_END = 21 * 60;

/** Past this share of the free time, the meter warns: a day planned to the minute has no slack. */
export const TIGHT_AT = 0.85;

/** One piece of work he chose for today, with his estimate. */
export interface Pick {
  /** Unique within the plan. A task's id when it came from a task. */
  id: string;
  title: string;
  minutes: number;
  category: Category;
  /** The task it came from, or null for a free-form block typed in the flow. */
  taskId: string | null;
}

export interface Window {
  startMin: number;
  endMin: number;
}

/**
 * The part of working hours still ahead.
 *
 * On the day itself, the morning already spent is not free time: planning at 10:40 must not
 * propose a block at 09:00. The start is rounded up to the quarter hour so a block never
 * starts at 10:43. On any other day the whole window stands — the engine's `day` is the
 * authority on which day is being planned, not the machine's clock.
 */
export function planningWindow(day: string, now: Date, start = WORK_START, end = WORK_END): Window {
  if (dayKey(now.toISOString()) !== day) return { startMin: start, endMin: end };
  const nowMin = minutesOfDay(now.toISOString());
  const rounded = Math.ceil(nowMin / 15) * 15;
  const startMin = Math.min(end, Math.max(start, rounded));
  return { startMin, endMin: end };
}

/** The events that occupy time. An open-ended deadline is a moment, not a block. */
export function obstacles(events: PlannerEvent[]): PlannerEvent[] {
  return events.filter((e) => !(e.kind === "deadline" && e.end == null));
}

/** The free intervals a block can actually use, earliest first. */
export function freeGaps(events: PlannerEvent[], window: Window): Gap[] {
  return gapsFor(obstacles(events), window.startMin, window.endMin).filter((g) => gapFits(g, MIN_BLOCK_MIN));
}

export function freeMinutes(gaps: Gap[]): number {
  return gaps.reduce((sum, g) => sum + (g.endMin - g.startMin), 0);
}

export interface Placed {
  pick: Pick;
  startMin: number;
  endMin: number;
}

/**
 * How the day reads, as one word.
 *  - `empty`: nothing picked yet.
 *  - `full`: there is no usable free time at all.
 *  - `ok` / `tight` / `over`: planned time against free time, with `tight` from TIGHT_AT.
 */
export type FitLevel = "empty" | "full" | "ok" | "tight" | "over";

export interface Fit {
  placed: Placed[];
  /** Picks no remaining gap can hold whole, in pick order. */
  overflow: Pick[];
  plannedMin: number;
  freeMin: number;
  /** Planned minus free, when positive. What the meter says he is over by. */
  overByMin: number;
  /** Planned over free. Infinity when there is no free time and something is picked. */
  ratio: number;
  level: FitLevel;
}

/**
 * Places picks into gaps, first-fit in pick order, and reports what is left over.
 *
 * A pick shorter than MIN_BLOCK_MIN is raised to it, so no placed block is ever smaller than
 * the shortest block worth proposing — the same floor the Tasks dayline holds.
 */
export function fitPlan(picks: Pick[], gaps: Gap[]): Fit {
  // Working copies: placing a block consumes the front of its gap.
  const room = gaps.map((g) => ({ startMin: g.startMin, endMin: g.endMin }));
  const placed: Placed[] = [];
  const overflow: Pick[] = [];

  for (const raw of picks) {
    const pick = raw.minutes < MIN_BLOCK_MIN ? { ...raw, minutes: MIN_BLOCK_MIN } : raw;
    const slot = room.find((r) => r.endMin - r.startMin >= pick.minutes);
    if (!slot) {
      overflow.push(pick);
      continue;
    }
    placed.push({ pick, startMin: slot.startMin, endMin: slot.startMin + pick.minutes });
    slot.startMin += pick.minutes;
  }

  const plannedMin = picks.reduce((sum, p) => sum + Math.max(MIN_BLOCK_MIN, p.minutes), 0);
  const freeMin = freeMinutes(gaps);
  const ratio = freeMin === 0 ? (plannedMin === 0 ? 0 : Infinity) : plannedMin / freeMin;
  const level: FitLevel =
    freeMin === 0
      ? "full"
      : plannedMin === 0
      ? "empty"
      : ratio > 1
      ? "over"
      : ratio >= TIGHT_AT
      ? "tight"
      : "ok";

  // Chronological, not pick order: the review reads as the day will.
  placed.sort((a, b) => a.startMin - b.startMin);
  return { placed, overflow, plannedMin, freeMin, overByMin: Math.max(0, plannedMin - freeMin), ratio, level };
}

/** "3h 15m", "45m", "2h". Minutes are the unit he estimated in, so they stay visible. */
export function formatMinutes(total: number): string {
  const m = Math.max(0, Math.round(total));
  const h = Math.floor(m / 60);
  const rest = m % 60;
  if (h === 0) return `${rest}m`;
  return rest === 0 ? `${h}h` : `${h}h ${rest}m`;
}

/** The event title a block is written with. Matches the "Focus — …" blocks already on his day. */
export function blockTitle(pick: Pick): string {
  return `Focus — ${pick.title}`;
}

/**
 * A minutes-from-midnight time on the plan's day, as an unambiguous instant.
 *
 * Goes through the same zone-correct conversion the scheduler form uses. `isoAt` in the Tasks
 * workspace hardcodes −07:00, which is right in September and an hour wrong whenever Vancouver is on standard time —
 * acceptable for a local preview, not for something written to a real calendar.
 */
export function instantOn(day: string, minutes: number): string | null {
  return fromLocalInput(`${day}T${clock(minutes)}`);
}

/**
 * Exactly what will be sent, one request per placed block.
 *
 * No `calendarId`: the engine then writes to the primary calendar, which is what the scheduler
 * does too. Task list names are not calendar ids, and sending one as if it were would fail or,
 * worse, land somewhere unexpected.
 */
export function toRequests(placed: Placed[], day: string): CreateEventRequest[] {
  const out: CreateEventRequest[] = [];
  for (const p of placed) {
    const start = instantOn(day, p.startMin);
    const end = instantOn(day, p.endMin);
    if (!start || !end) continue;
    out.push({
      title: blockTitle(p.pick),
      start,
      end,
      description: p.pick.taskId
        ? `Focus block for the task “${p.pick.title}”. Planned in Daily Planner.`
        : "Focus block planned in Daily Planner.",
    });
  }
  return out;
}

/** The plan as plain text, for the read-only case where he adds the blocks himself. */
export function planText(placed: Placed[], day: string): string {
  const lines = placed.map((p) => `${clock(p.startMin)}–${clock(p.endMin)}  ${blockTitle(p.pick)}`);
  return [`Plan for ${day}`, ...lines].join("\n");
}

/** A task he could pick, with why it sits where it does. */
export interface Candidate {
  id: string;
  title: string;
  category: Category;
  list: string;
  due: string | null;
  /** Due today or earlier — pinned above everything else. */
  pinned: boolean;
  reason: string;
}

/**
 * Open tasks in `rankFocus` order, with anything due today or earlier marked pinned.
 *
 * The ranking is Focus's, reused rather than re-derived, so a task that Focus calls overdue is
 * never "no date" here. Pinned is the ranks that mean "today or already late"; `rankFocus`
 * already sorts those first, so pinning only has to mark them.
 */
export function candidates(lists: TaskList[], now: Date): Candidate[] {
  const listOf = new Map<string, string>();
  for (const list of lists) for (const item of list.items) listOf.set(item.id, list.name);

  const pinnedRanks = new Set<number>([RANK.overdue, RANK.now, RANK.next, RANK.today]);
  return rankFocus({ events: [], lists, drafts: [], now })
    .filter((item) => item.source.kind === "task")
    .map((item) => ({
      id: item.id,
      title: item.title,
      category: item.category,
      list: listOf.get(item.id) ?? "",
      due: item.at,
      pinned: pinnedRanks.has(item.rank),
      reason: item.reason,
    }));
}
