/*
 * Synthetic linked-focus-block data for the read-only round.
 *
 * Google Tasks stores a due DATE and no time. The product's answer to that is a
 * *linked calendar focus block*: timed work lives on the calendar, and the task
 * card shows the link. The engine does not yet return this relationship, so this
 * round supplies a small synthetic map (mirroring the mock schedule's
 * "Focus — Assignment 3" block) exactly as the Mail workspace supplies synthetic
 * display detail. Production replaces this with the real linkage; nothing here
 * writes anything.
 */

import { formatTime } from "../contract";

export interface LinkedBlock {
  /** Minutes from midnight the focus block starts (Vancouver wall clock). */
  startMin: number;
  durationMin: number;
  calendar: string;
}

const LINKS: Record<string, LinkedBlock> = {
  // "Assignment 3" is worked in a 11:00–12:00 focus block on the planning day.
  t1: { startMin: 11 * 60, durationMin: 60, calendar: "School" },
};

export function linkedBlockFor(taskId: string): LinkedBlock | null {
  return LINKS[taskId] ?? null;
}

/** "11:00–12:00 · School" — the block carries a time; the task never does. */
export function describeBlock(block: LinkedBlock, day: string): string {
  const start = isoAt(day, block.startMin);
  const end = isoAt(day, block.startMin + block.durationMin);
  return `${formatTime(start)}–${formatTime(end)} · ${block.calendar}`;
}

/** Build an ISO datetime for a minutes-from-midnight time on the given day. */
export function isoAt(day: string, minutes: number): string {
  const h = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0");
  const m = (minutes % 60).toString().padStart(2, "0");
  // The planning day is Vancouver-local; PDT is -07:00 on the mock day. Using a
  // fixed offset here only affects the synthetic proposal preview, never a write.
  return `${day}T${h}:${m}:00-07:00`;
}
