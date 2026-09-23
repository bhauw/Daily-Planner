/*
 * Insertion — where a dragged task actually lands on the dayline.
 *
 * The old drop mapped the cursor's Y to a ratio of the wrapper's height and
 * called that a time. That was wrong twice over: the Dayline is a *list of rows*
 * with varying heights, not a proportional timeline, so the ratio does not mean
 * what it claims; and the resulting time had no awareness of the blocks already
 * on the day, so a drop routinely proposed a block sitting on top of a class.
 *
 * What a person is actually doing when they drag a card into the middle of the
 * schedule is choosing a *gap* — "put it between these two". So this module
 * models the day as the free intervals between what is already there, and the
 * drop picks one:
 *
 *   - `gapsFor` turns the day's events into the gaps between them, merging
 *     overlapping blocks first so two overlapping classes do not invent a gap
 *     that does not exist. The interval before the first block and the one after
 *     the last are gaps too, so a drop at either end still slots.
 *   - `chooseGap` takes the boundary the cursor is nearest and returns the gap
 *     that will hold the block: the one at that boundary when it fits, otherwise
 *     the nearest one that does, searching outward. Refusing the drop would be
 *     the easy answer and the worse one — the indicator moves to where the block
 *     is really going and says so, so what is shown is what is committed.
 *   - `placementFor` reads the block's start and length off the chosen gap, so
 *     the time comes from the gap rather than from the pixel under the cursor.
 *
 * Pure functions over minutes-from-midnight. Nothing here touches the DOM, and
 * nothing here writes — a drop still only opens the compose form.
 */

import type { PlannerEvent } from "../contract";

/** The shortest block worth proposing; a gap under this cannot take one. */
export const MIN_BLOCK_MIN = 15;
/** The length a block takes when the gap is open-ended enough to allow it. */
export const PREFERRED_BLOCK_MIN = 60;

/** A free interval on the day, and the blocks it sits between. */
export interface Gap {
  /** Position in the gap list; 0 is the interval before the first block. */
  index: number;
  startMin: number;
  endMin: number;
  /** Event id of the block just before this gap, or null at the top of the day. */
  afterId: string | null;
  /** Event id of the block just after this gap, or null at the end of the day. */
  beforeId: string | null;
}

export interface Placement {
  gap: Gap;
  startMin: number;
  durationMin: number;
  /** True when the gap is bounded on both sides — the "between two things" case. */
  between: boolean;
}

const ZONE = "America/Vancouver";
const HM = new Intl.DateTimeFormat("en-CA", {
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
  timeZone: ZONE,
});

/** Minutes from midnight (Vancouver wall clock) for an ISO instant, or null. */
export function minutesOfDay(iso: string | null): number | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = HM.formatToParts(d);
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? "0");
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  return h * 60 + m;
}

interface Span {
  id: string;
  startMin: number;
  endMin: number;
}

/**
 * The day's blocks as spans, sorted and clipped to the window. An event with no
 * end is given the minimum length so it still occupies the day rather than
 * silently becoming a zero-width mark that two gaps could form around.
 */
export function spansFor(events: PlannerEvent[], windowStart: number, windowEnd: number): Span[] {
  const spans: Span[] = [];
  for (const e of events) {
    const s = minutesOfDay(e.start);
    if (s == null) continue;
    const rawEnd = minutesOfDay(e.end);
    const en = rawEnd != null && rawEnd > s ? rawEnd : s + MIN_BLOCK_MIN;
    // Wholly outside the planning window: not context for a drop inside it.
    if (en <= windowStart || s >= windowEnd) continue;
    spans.push({ id: e.id, startMin: Math.max(windowStart, s), endMin: Math.min(windowEnd, en) });
  }
  return spans.sort((a, b) => a.startMin - b.startMin || a.endMin - b.endMin);
}

/**
 * The free intervals between the day's blocks, in order. Overlapping blocks are
 * merged first: two classes that overlap are one obstruction, not two with an
 * imaginary gap between them.
 *
 * The returned list always has (merged blocks + 1) entries, so gap `i` is the
 * interval *before* rendered block `i` — which is exactly the boundary index a
 * cursor between two rows produces.
 */
export function gapsFor(events: PlannerEvent[], windowStart: number, windowEnd: number): Gap[] {
  const spans = spansFor(events, windowStart, windowEnd);

  const merged: Span[] = [];
  for (const span of spans) {
    const last = merged[merged.length - 1];
    if (last && span.startMin <= last.endMin) {
      // Keep the FIRST block's id: it is the row the gap is measured after.
      last.endMin = Math.max(last.endMin, span.endMin);
    } else {
      merged.push({ ...span });
    }
  }

  const gaps: Gap[] = [];
  let cursor = windowStart;
  merged.forEach((span, i) => {
    gaps.push({
      index: i,
      startMin: cursor,
      endMin: Math.max(cursor, span.startMin),
      afterId: i === 0 ? null : merged[i - 1].id,
      beforeId: span.id,
    });
    cursor = Math.max(cursor, span.endMin);
  });
  gaps.push({
    index: merged.length,
    startMin: cursor,
    endMin: Math.max(cursor, windowEnd),
    afterId: merged.length === 0 ? null : merged[merged.length - 1].id,
    beforeId: null,
  });

  return gaps;
}

export function gapFits(gap: Gap, minMin: number = MIN_BLOCK_MIN): boolean {
  return gap.endMin - gap.startMin >= minMin;
}

/**
 * The gap a drop at `boundary` lands in — that gap when a block fits, otherwise
 * the nearest one that does, searching outward and preferring the earlier of two
 * equally distant candidates. Null when the day has no room at all.
 */
export function chooseGap(gaps: Gap[], boundary: number, minMin: number = MIN_BLOCK_MIN): Gap | null {
  if (gaps.length === 0) return null;
  const target = Math.min(gaps.length - 1, Math.max(0, boundary));
  for (let step = 0; step < gaps.length; step++) {
    const before = gaps[target - step];
    if (before && gapFits(before, minMin)) return before;
    const after = gaps[target + step];
    if (after && gapFits(after, minMin)) return after;
  }
  return null;
}

/** Start and length for a block dropped into this gap: the gap supplies both. */
export function placementFor(gap: Gap): Placement {
  const room = gap.endMin - gap.startMin;
  return {
    gap,
    startMin: gap.startMin,
    durationMin: Math.max(MIN_BLOCK_MIN, Math.min(PREFERRED_BLOCK_MIN, room)),
    between: gap.afterId !== null && gap.beforeId !== null,
  };
}

/**
 * Where the keyboard "Block time" path opens: the first gap that holds a full
 * preferred block, else the first that holds any block at all (on what it can
 * hold). A fixed default time was the old answer, and on the mock day it sat
 * exactly on the existing focus block — the form proposed a double-booking
 * without a word. Null when the day has no room.
 */
export function firstOpening(gaps: Gap[]): { startMin: number; durationMin: number } | null {
  const full = gaps.find((g) => gapFits(g, PREFERRED_BLOCK_MIN));
  if (full) return { startMin: full.startMin, durationMin: PREFERRED_BLOCK_MIN };
  const any = gaps.find((g) => gapFits(g, MIN_BLOCK_MIN));
  return any ? { startMin: any.startMin, durationMin: any.endMin - any.startMin } : null;
}

/**
 * The first block that [startMin, endMin) overlaps, or null. Touching edges do
 * not count — 10:20 straight after a lecture ending at 10:20 is free time.
 */
export function overlapFor(events: PlannerEvent[], startMin: number, endMin: number): PlannerEvent | null {
  for (const e of events) {
    const s = minutesOfDay(e.start);
    if (s == null) continue;
    const rawEnd = minutesOfDay(e.end);
    const en = rawEnd != null && rawEnd > s ? rawEnd : s + MIN_BLOCK_MIN;
    if (startMin < en && endMin > s) return e;
  }
  return null;
}

/** "09:30" — a wall-clock label for a minutes-from-midnight value. */
export function clock(minutes: number): string {
  const h = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0");
  const m = (minutes % 60).toString().padStart(2, "0");
  return `${h}:${m}`;
}

/** What the insertion indicator says — where it slots, and the time it takes. */
export function describePlacement(p: Placement): string {
  const end = p.startMin + p.durationMin;
  const where = p.between
    ? "Between these"
    : p.gap.beforeId !== null
      ? "Before the first block"
      : p.gap.afterId !== null
        ? "After the last block"
        : "On an open day";
  return `${where} · ${clock(p.startMin)}–${clock(end)}`;
}
