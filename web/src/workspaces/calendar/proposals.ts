/*
 * Reschedule proposals — local, non-committing. Dragging or key-moving a flexible
 * block produces a Proposal: a before→after change that needs approval and is
 * never sent anywhere this round. Approving/discarding changes local state only.
 */

import type { PlannerEvent } from "../contract";
import { busyForDay, collides, fmtMinutes, type BusyBlock } from "./scheduling";
import { dayKey as dayKeyOf, isoAtVan, partsOfKey, weekdayShort } from "./tz";

export interface Proposal {
  event: PlannerEvent;
  /** The day it is proposed ONTO — which a drag into another column makes different from… */
  dayKey: string;
  /** …the day it is on now. Kept so the diff can say "Tue 11:00 → Wed 14:00", not just times. */
  fromDayKey: string;
  fromStart: number; // minutes from midnight
  toStart: number;
  duration: number;
  /** safe reason string when the target time overlaps another commitment. */
  collision: string | null;
}

export function proposalFor(
  event: PlannerEvent,
  dayKey: string,
  fromStart: number,
  toStart: number,
  duration: number,
  busy: BusyBlock[],
): Proposal {
  const hit = collides(toStart, duration, busy, event.id);
  return {
    event,
    dayKey,
    fromDayKey: dayKeyOf(event.start),
    fromStart,
    toStart,
    duration,
    collision: hit ? `Overlaps ${hit.event.title} (incl. its buffer)` : null,
  };
}

/** "Tue 14:00" — a proposal's end of the diff always names its day. */
export function whenLabel(key: string, minutes: number): string {
  return `${weekdayShort(new Date(`${key}T12:00:00Z`).toISOString())} ${fmtMinutes(minutes)}`;
}

/**
 * The event as it stands once a proposal is accepted locally: same block, new day and time.
 * Approval used to keep only the id, so every view fell back to the original start and the
 * block visibly snapped back to where it came from.
 */
export function applyAccepted(event: PlannerEvent, p: Proposal): PlannerEvent {
  const { y, m, d } = partsOfKey(p.dayKey);
  const start = isoAtVan(y, m, d, Math.floor(p.toStart / 60), p.toStart % 60);
  const end = new Date(new Date(start).getTime() + p.duration * 60_000).toISOString();
  return { ...event, start, end: event.end ? end : null };
}

export { busyForDay };
