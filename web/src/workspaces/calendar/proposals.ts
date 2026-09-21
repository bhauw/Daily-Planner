/*
 * Reschedule proposals — local, non-committing. Dragging or key-moving a flexible
 * block produces a Proposal: a before→after change that needs approval and is
 * never sent anywhere this round. Approving/discarding changes local state only.
 */

import type { PlannerEvent } from "../contract";
import { busyForDay, collides, type BusyBlock } from "./scheduling";

export interface Proposal {
  event: PlannerEvent;
  dayKey: string;
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
    fromStart,
    toStart,
    duration,
    collision: hit ? `Overlaps ${hit.event.title} (incl. its buffer)` : null,
  };
}

export { busyForDay };
