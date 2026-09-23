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

/**
 * The block's own span in minutes from its START day's midnight (Vancouver). The end comes
 * from the real duration, so an event that crosses midnight ends past 1440 rather than being
 * clamped to its start — the old Math.max over two minutes-of-day values turned a 30-hour
 * red-eye into a zero-length event that drew as a 20px sliver.
 */
export function eventInterval(event: PlannerEvent): Interval | null {
  const s = minutesOfDay(event.start);
  if (Number.isNaN(s)) return null;
  if (!event.end) return { start: s, end: s + 30 };
  const ms = new Date(event.end).getTime() - new Date(event.start).getTime();
  if (Number.isNaN(ms)) return { start: s, end: s + 30 };
  return { start: s, end: s + Math.max(0, Math.round(ms / 60_000)) };
}

const DAY_MIN = 24 * 60;

/**
 * The part of an event that falls on one Vancouver calendar day, in that day's minutes
 * (0–1440), or null when it is not on that day. Grids file an event under every day it
 * touches, not just the day it starts — a night shift is still on Tuesday at 01:00. An event
 * ending exactly at midnight does not spill onto the next day.
 */
export function intervalOnDay(event: PlannerEvent, key: string): Interval | null {
  const iv = eventInterval(event);
  if (!iv) return null;
  const startKey = dayKey(event.start);
  if (key < startKey) return null;
  if (key === startKey) return { start: iv.start, end: Math.min(iv.end, DAY_MIN) };
  if (!event.end || iv.end <= DAY_MIN) return null;
  // Later days are read off the end instant in Vancouver, so a DST change in between cannot
  // shift the last day's end by an hour.
  const endKey = dayKey(event.end);
  const endMin = minutesOfDay(event.end);
  if (key > endKey || (key === endKey && endMin === 0)) return null;
  return { start: 0, end: key === endKey ? endMin : DAY_MIN };
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
    // Every day the event touches, clipped to that day — not its start day only.
    const iv = intervalOnDay(e, key);
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

/**
 * Why a slot starts where it does, one line each. The bounding event is the one whose buffer
 * the slot starts at — not the nearest earlier in-person event, which made a 12:15 slot blame
 * "transit from AQ 3150" for a lecture that ended at 10:20 when the 11:00 focus block's buffer
 * was the real constraint.
 */
function reasonsFor(gapStart: number, fallback: boolean, busy: BusyBlock[], floor: number | null): string[] {
  const reasons: string[] = [];
  const bound = busy
    .filter((b) => b.buffered.end === gapStart)
    .sort((a, b) => b.interval.end - a.interval.end)[0];
  if (bound) {
    const buffer = bufferFor(bound.event);
    reasons.push(
      bound.event.location
        ? `${buffer} min travel buffer after ${bound.event.title} (${bound.event.location})`
        : `${buffer} min buffer after ${bound.event.title}`,
    );
  } else if (floor != null && gapStart === floor) {
    reasons.push("The next opening from now");
  } else {
    reasons.push("Nothing earlier in the window to work around");
  }
  if (fallback) {
    reasons.push(`After-hours (${fmtMinutes(FALLBACK_START)}–${fmtMinutes(FALLBACK_END)}) fallback — offered only because normal hours had no opening`);
  } else {
    reasons.push(`Inside normal hours (${fmtMinutes(NORMAL_START)}–${fmtMinutes(NORMAL_END)})`);
  }
  return reasons;
}

function makeSlot(key: string, gapStart: number, duration: number, fallback: boolean, busy: BusyBlock[], floor: number | null): Slot {
  return {
    dayKey: key,
    weekday: `${key}`, // replaced below with a weekday label from an instant
    start: gapStart,
    end: gapStart + duration,
    fallback,
    zone: "",
    reasons: reasonsFor(gapStart, fallback, busy, floor),
  };
}

/** Lead time before a slot can start today: nobody can be at a meeting that starts this minute. */
export const NOW_LEAD_MIN = 15;

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
  /**
   * The clock. Without it the whole window is offered (tests, and the "as if" illustration);
   * with it, days before today are skipped and today starts after now plus a lead, rounded up
   * to the step — at 15:00 the finder was still ranking today's 12:15 first.
   */
  now?: Date,
): Slot[] {
  const normal: Slot[] = [];
  const fallback: Slot[] = [];
  const nowIso = now ? now.toISOString() : null;
  const todayKey = nowIso ? dayKey(nowIso) : null;
  const floorToday = nowIso ? Math.ceil((minutesOfDay(nowIso) + NOW_LEAD_MIN) / STEP) * STEP : null;

  for (let i = 0; i < days; i++) {
    const key = addDays(fromKey, i);
    if (todayKey && key < todayKey) continue;
    const floor = key === todayKey ? floorToday : null;
    const clip = (w: Interval): Interval => (floor == null ? w : { start: Math.max(w.start, floor), end: w.end });
    // A representative instant at noon, to read the weekday/zone in Vancouver.
    const noonInstant = new Date(`${key}T12:00:00Z`).toISOString();
    if (isWeekend(noonInstant)) continue;
    const weekday = weekdayShort(noonInstant);

    const busy = busyForDay(planningEvents, key);
    const buffered = busy.map((b) => b.buffered);

    const normalGaps = freeGaps(clip(NORMAL_WINDOW), buffered, duration);
    if (normalGaps.length > 0) {
      for (const g of normalGaps) {
        const slot = makeSlot(key, g.start, duration, false, busy, floor);
        slot.weekday = weekday;
        slot.zone = zoneAbbrev(new Date(`${key}T${String(Math.floor(g.start / 60)).padStart(2, "0")}:00:00Z`).toISOString());
        normal.push(slot);
      }
    } else {
      const fbGaps = freeGaps(clip(FALLBACK_WINDOW), buffered, duration);
      for (const g of fbGaps) {
        const slot = makeSlot(key, g.start, duration, true, busy, floor);
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

/**
 * What an instant range would sit on, as safe text — "Overlaps ECONOMICS 250 Lecture (incl. 30 min
 * buffer)" — or null when it is clear. The one conflict check both the Calendar's drag and the
 * app-wide "Move it" use, so the two can never disagree about whether a time is free.
 */
export function conflictFor(
  events: PlannerEvent[],
  startIso: string,
  endIso: string,
  ignoreId?: string,
): string | null {
  const start = new Date(startIso).getTime();
  const end = new Date(endIso).getTime();
  if (Number.isNaN(start) || Number.isNaN(end) || end <= start) return null;
  const s = minutesOfDay(startIso);
  const hit = collides(s, Math.round((end - start) / 60_000), busyForDay(events, dayKey(startIso)), ignoreId);
  return hit ? `Overlaps ${hit.event.title} (incl. ${bufferFor(hit.event)} min buffer)` : null;
}

/**
 * "14:15" — the app's one clock. Everything else (formatTime, the Dayline, Tasks) is 24-hour,
 * so the Calendar writing "2 PM" beside "14:00" on the same screen made two conventions out of
 * one; this now matches formatTime exactly.
 */
export function fmtMinutes(mins: number): string {
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}
