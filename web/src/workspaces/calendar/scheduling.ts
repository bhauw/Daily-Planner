/*
 * Scheduling engine — pure wall-clock math for the Calendar workspace.
 *
 * Everything here works in minutes-from-midnight in America/Vancouver (via
 * tz.ts, which derives the offset from Intl at each instant — PDT vs PST is
 * automatic, never hardcoded). No React, no DOM: this is testable in isolation
 * and is the single source of truth for busy time, buffers, free gaps, the
 * availability ranking, and why a block is or isn't movable.
 *
 * Product rules encoded here (from the brief, binding):
 *  - Normal hours 9 AM–6 PM on weekdays. 6–8 PM is a fallback, offered only when
 *    a weekday has no 9–6 opening, and always labelled as a fallback.
 *  - Prefer the next weekday's normal hours over a same-day evening fallback.
 *  - Default coffee chat is 45 minutes.
 *  - Buffers: 15 min around virtual meetings, 30 min around in-person ones
 *    (an event with a location is treated as in-person).
 *  - A "flexible" block (a focus/deadline work block with a duration) may be
 *    proposed to a new time. Hard commitments (classes, meetings, extracurricular)
 *    are fixed and explain why rather than moving.
 */

import type { PlannerEvent } from "../contract";
import { minutesOfDay, dayKey, weekdayShort, isWeekend, addDays, zoneAbbrev } from "./tz";

export interface Interval {
  start: number; // minutes from local midnight
  end: number;
}

export const SLOT_MIN = 45; // default coffee chat
export const NORMAL_START = 9 * 60; // 09:00
export const NORMAL_END = 18 * 60; // 18:00
export const FALLBACK_START = 18 * 60; // 18:00
export const FALLBACK_END = 20 * 60; // 20:00
export const STEP = 15;

export const NORMAL_WINDOW: Interval = { start: NORMAL_START, end: NORMAL_END };
export const FALLBACK_WINDOW: Interval = { start: FALLBACK_START, end: FALLBACK_END };

/** In-person commitments (those with a location) need more turnaround than virtual. */
export function bufferFor(event: PlannerEvent): number {
  return event.location ? 30 : 15;
}

/** True for a movable work block: a deadline-kind block that occupies a span. */
export function isFlexible(event: PlannerEvent): boolean {
  return event.kind === "deadline" && event.end != null;
}

/** Why a fixed block can't be proposed to a new time — safe, human text. */
export function fixedReason(event: PlannerEvent): string {
  if (event.category === "school" && event.kind === "event") return "Fixed class time — can't be moved here";
  if (event.kind === "extracurricular") return "Standing commitment — held at a fixed time";
  if (event.location) return "Confirmed in-person meeting — treated as a hard conflict";
  return "Confirmed commitment — treated as a hard conflict";
}

/** The block's own span in minutes-from-midnight (Vancouver). */
export function eventInterval(event: PlannerEvent): Interval | null {
  const s = minutesOfDay(event.start);
  if (Number.isNaN(s)) return null;
  const e = event.end ? minutesOfDay(event.end) : s + 30;
  return { start: s, end: Math.max(s, e) };
}

export interface BusyBlock {
  event: PlannerEvent;
  interval: Interval; // the block itself
  buffered: Interval; // block ± its buffer
}

/** Busy blocks on one calendar day, buffered and sorted by start. */
export function busyForDay(events: PlannerEvent[], key: string): BusyBlock[] {
  const out: BusyBlock[] = [];
  for (const e of events) {
    if (dayKey(e.start) !== key) continue;
    const iv = eventInterval(e);
    if (!iv) continue;
    const b = bufferFor(e);
    out.push({ event: e, interval: iv, buffered: { start: iv.start - b, end: iv.end + b } });
  }
  return out.sort((a, b) => a.interval.start - b.interval.start);
}

function mergeIntervals(ivs: Interval[]): Interval[] {
  const sorted = [...ivs].sort((a, b) => a.start - b.start);
  const merged: Interval[] = [];
  for (const iv of sorted) {
    const last = merged[merged.length - 1];
    if (last && iv.start <= last.end) last.end = Math.max(last.end, iv.end);
    else merged.push({ ...iv });
  }
  return merged;
}

/** Open gaps of at least `duration` inside `window`, given buffered busy time. */
export function freeGaps(window: Interval, busy: Interval[], duration: number): Interval[] {
  const blocking = mergeIntervals(
    busy
      .map((b) => ({ start: Math.max(window.start, b.start), end: Math.min(window.end, b.end) }))
      .filter((b) => b.end > b.start),
  );
  const gaps: Interval[] = [];
  let cursor = window.start;
  for (const b of blocking) {
    if (b.start - cursor >= duration) gaps.push({ start: cursor, end: b.start });
    cursor = Math.max(cursor, b.end);
  }
  if (window.end - cursor >= duration) gaps.push({ start: cursor, end: window.end });
  return gaps;
}

export interface Slot {
  dayKey: string;
  weekday: string; // "Tue"
  start: number; // minutes from midnight
  end: number;
  fallback: boolean; // true when drawn from the 6–8 PM fallback window
  zone: string; // "PDT" | "PST" — proves DST handling
  reasons: string[]; // visible reasoning, one line each
}

function reasonsFor(
  _key: string,
  gapStart: number,
  _duration: number,
  fallback: boolean,
  busy: BusyBlock[],
): string[] {
  const reasons: string[] = [];
  // Nearest preceding in-person commitment, for a transit note.
  const priorInPerson = busy
    .filter((b) => b.event.location && b.interval.end <= gapStart)
    .sort((a, b) => b.interval.end - a.interval.end)[0];
  if (priorInPerson) {
    const gapAfter = gapStart - priorInPerson.interval.end;
    reasons.push(`${bufferFor(priorInPerson.event)} min transit from ${priorInPerson.event.location}`);
    if (gapAfter >= bufferFor(priorInPerson.event)) reasons.push("Clear of the prior meeting's buffer");
  } else {
    reasons.push("No conflicts in the surrounding window");
  }
  if (fallback) {
    reasons.push("After-hours (6–8 PM) fallback — offered only because 9–6 had no opening");
  } else {
    reasons.push("Inside normal hours (9 AM–6 PM)");
  }
  return reasons;
}

function makeSlot(key: string, gapStart: number, duration: number, fallback: boolean, busy: BusyBlock[]): Slot {
  return {
    dayKey: key,
    weekday: `${key}`, // replaced below with a weekday label from an instant
    start: gapStart,
    end: gapStart + duration,
    fallback,
    zone: "",
    reasons: reasonsFor(key, gapStart, duration, fallback, busy),
  };
}

/**
 * Ranked availability for a `duration`-minute meeting across the next `days`
 * weekdays from `fromKey`. Normal-hour slots on any day always outrank a same-day
 * evening fallback (we "prefer the next day first"). Weekends are skipped entirely.
 */
export function findAvailability(
  planningEvents: PlannerEvent[],
  fromKey: string,
  duration = SLOT_MIN,
  days = 7,
): Slot[] {
  const normal: Slot[] = [];
  const fallback: Slot[] = [];

  for (let i = 0; i < days; i++) {
    const key = addDays(fromKey, i);
    // A representative instant at noon, to read the weekday/zone in Vancouver.
    const noonInstant = new Date(`${key}T12:00:00Z`).toISOString();
    if (isWeekend(noonInstant)) continue;
    const weekday = weekdayShort(noonInstant);

    const busy = busyForDay(planningEvents, key);
    const buffered = busy.map((b) => b.buffered);

    const normalGaps = freeGaps(NORMAL_WINDOW, buffered, duration);
    if (normalGaps.length > 0) {
      for (const g of normalGaps) {
        const slot = makeSlot(key, g.start, duration, false, busy);
        slot.weekday = weekday;
        slot.zone = zoneAbbrev(new Date(`${key}T${String(Math.floor(g.start / 60)).padStart(2, "0")}:00:00Z`).toISOString());
        normal.push(slot);
      }
    } else {
      const fbGaps = freeGaps(FALLBACK_WINDOW, buffered, duration);
      for (const g of fbGaps) {
        const slot = makeSlot(key, g.start, duration, true, busy);
        slot.weekday = weekday;
        slot.zone = zoneAbbrev(new Date(`${key}T${String(Math.floor(g.start / 60)).padStart(2, "0")}:00:00Z`).toISOString());
        fallback.push(slot);
      }
    }
  }
  // Normal-hours slots (all days) rank above every evening fallback.
  return [...normal, ...fallback];
}

/** True when a proposed [start, start+duration] overlaps any buffered busy block. */
export function collides(start: number, duration: number, busy: BusyBlock[], ignoreId?: string): BusyBlock | null {
  const end = start + duration;
  for (const b of busy) {
    if (b.event.id === ignoreId) continue;
    if (start < b.buffered.end && end > b.buffered.start) return b;
  }
  return null;
}

export function fmtMinutes(mins: number): string {
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  const hh = ((h + 11) % 12) + 1;
  const ap = h < 12 ? "AM" : "PM";
  return m === 0 ? `${hh} ${ap}` : `${hh}:${String(m).padStart(2, "0")} ${ap}`;
}
