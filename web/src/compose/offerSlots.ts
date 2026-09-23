/*
 * Offer times — turning "what works for you?" into three real openings, as text.
 *
 * A recruiter writes "happy to chat, what works for you?" and the reply that follows is a
 * round-trip over times. Hosted booking links solve that elsewhere, and the fence rules them
 * out: nothing here publishes his calendar. Pasting a few genuine free slots into the reply gets
 * the same result locally, and he still reads and sends it himself.
 *
 * This module is the pure half: which slots to suggest, and the instruction that asks the
 * assistant to write them into a reply. No React, no fetch — so the two promises that matter are
 * testable on their own:
 *
 *  1. The slots are the calendar's own. Every suggestion is a slot `findAvailability` returned
 *     for the same events, duration and days — the same engine the Calendar's Availability view
 *     uses, with its buffers, normal-hours rule and labelled 6–8 PM fallback. Nothing here
 *     invents a time or re-derives busy-ness a second way.
 *
 *  2. Only TIMES leave the Mac. The instruction is built from a slot's day, start, end and zone
 *     and nothing else. A slot also carries `reasons`, and those can name a venue ("30 min
 *     transit from Example Cafe") — that is for his eyes in the picker, never for the prompt.
 *     Event titles, locations and attendees are never read by the builder at all, so there is
 *     no string to leak rather than a filter to get right.
 *
 * Bounded to PlannerReplyRequest.maxInstructionBytes (1000 UTF-8 bytes): the engine refuses a
 * longer instruction outright, so the builder drops trailing slots rather than hand it one.
 */

import type { PlannerEvent } from "../api/client";
import { findAvailability, SLOT_MIN, type Slot } from "../workspaces/calendar/scheduling";
import { addDays, isWeekend, partsOfKey } from "../workspaces/calendar/tz";

/** Matches PlannerReplyRequest.maxInstructionBytes, so the engine never has to refuse one. */
export const MAX_INSTRUCTION_BYTES = 1000;

/** How many slots the picker suggests, and how many of those start ticked. */
export const SUGGEST_MAX = 5;
export const PRECHECKED = 3;

/** The durations offered. 45 is the product's default coffee chat (scheduling.ts SLOT_MIN). */
export const OFFER_DURATIONS = [30, 45, 60] as const;
export const DEFAULT_DURATION = SLOT_MIN;

/** "Next N business days". 5 is a working week; 3 is for "this week, soon". */
export const OFFER_HORIZONS = [3, 5] as const;
export const DEFAULT_HORIZON = 5;

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export interface OfferWindow {
  /** The first day the calendar read covers, "YYYY-MM-DD" — today (WeekResponse.start). */
  start: string;
  /** How many days it covers, today included (WeekResponse.days). */
  days: number;
}

export interface Suggestion {
  /** Ranked slots to offer, at most SUGGEST_MAX. Every one is a findAvailability slot. */
  slots: Slot[];
  /** The business days actually searched, first to last. Empty when the window has none. */
  searched: string[];
  /** True when the calendar read ends before N business days did, so fewer were searched. */
  clipped: boolean;
}

/**
 * The next `businessDays` weekdays after today, stopping where the calendar read stops.
 *
 * Starts TOMORROW. A reply offering "today at 2" is usually stale by the time it is read, and
 * today's earlier openings have already passed — findAvailability has no clock, so a same-day
 * search would happily offer 9 AM at 3 PM.
 *
 * Stops at the window's edge because a day the engine did not read has no events in it, and a
 * day with no events looks entirely free. Offering a time on a day nobody checked is the one
 * failure this feature must not have, so the horizon shrinks and `clipped` says so.
 */
export function businessDaysAhead(window: OfferWindow, businessDays: number): { days: string[]; clipped: boolean } {
  const last = addDays(window.start, Math.max(0, window.days - 1));
  const days: string[] = [];
  for (let i = 1; days.length < businessDays; i++) {
    const key = addDays(window.start, i);
    if (key > last) return { days, clipped: true };
    if (!isWeekend(`${key}T12:00:00Z`)) days.push(key);
  }
  return { days, clipped: false };
}

/**
 * The slots worth offering: one per day first, so three suggestions are three different days.
 *
 * findAvailability lists every normal-hours gap in day order, so its first three are often all
 * Thursday. Someone replying to a recruiter wants spread — Thursday morning, Friday afternoon,
 * Monday — so the first pass takes each day's earliest opening, the second pass fills from the
 * rest in the engine's order, and after-hours fallbacks come last exactly as the engine ranks
 * them. Selection only: every slot returned is one the engine produced, unaltered.
 */
export function suggestSlots(
  events: PlannerEvent[],
  window: OfferWindow,
  duration: number,
  businessDays: number,
  max = SUGGEST_MAX,
): Suggestion {
  const { days, clipped } = businessDaysAhead(window, businessDays);
  if (days.length === 0) return { slots: [], searched: [], clipped };

  const first = days[0];
  const span = daysBetween(first, days[days.length - 1]) + 1;
  const all = findAvailability(events, first, duration, span);

  const normal = all.filter((s) => !s.fallback);
  const fallback = all.filter((s) => s.fallback);

  const picked: Slot[] = [];
  const seenDay = new Set<string>();
  for (const s of normal) {
    if (picked.length >= max) break;
    if (seenDay.has(s.dayKey)) continue;
    seenDay.add(s.dayKey);
    picked.push(s);
  }
  for (const s of [...normal, ...fallback]) {
    if (picked.length >= max) break;
    if (!picked.includes(s)) picked.push(s);
  }
  // Shown in time order: the picker reads like a calendar, not a leaderboard.
  picked.sort((a, b) => (a.dayKey === b.dayKey ? a.start - b.start : a.dayKey < b.dayKey ? -1 : 1));
  return { slots: picked, searched: days, clipped };
}

function daysBetween(a: string, b: string): number {
  const pa = partsOfKey(a);
  const pb = partsOfKey(b);
  return Math.round((Date.UTC(pb.y, pb.m - 1, pb.d) - Date.UTC(pa.y, pa.m - 1, pa.d)) / 86_400_000);
}

/** "Thu Sep 24" — the day part of a slot, from its own key (no clock, no locale drift). */
export function slotDay(slot: Pick<Slot, "dayKey" | "weekday">): string {
  const { m, d } = partsOfKey(slot.dayKey);
  return `${slot.weekday} ${MONTHS[m - 1]} ${d}`;
}

function clock(mins: number): { hm: string; ap: string } {
  const h = Math.floor(mins / 60);
  return { hm: `${((h + 11) % 12) + 1}:${String(mins % 60).padStart(2, "0")}`, ap: h < 12 ? "AM" : "PM" };
}

/** "10:00–10:45 AM", or "11:30 AM–12:15 PM" when it crosses noon. */
export function slotRange(slot: Pick<Slot, "start" | "end">): string {
  const a = clock(slot.start);
  const b = clock(slot.end);
  return a.ap === b.ap ? `${a.hm}–${b.hm} ${b.ap}` : `${a.hm} ${a.ap}–${b.hm} ${b.ap}`;
}

/**
 * One slot as the recipient will read it: "Thu Sep 24, 10:00–10:45 AM PDT".
 *
 * The zone is on every line rather than once in a header, because a window that crosses the
 * November change holds PDT and PST slots side by side, and a single header would be wrong for
 * half of them.
 */
export function slotLine(slot: Pick<Slot, "dayKey" | "weekday" | "start" | "end" | "zone">): string {
  return `${slotDay(slot)}, ${slotRange(slot)}${slot.zone ? ` ${slot.zone}` : ""}`;
}

function bytes(s: string): number {
  return new TextEncoder().encode(s).length;
}

/**
 * The instruction for PlannerReplyRequest.customInstruction.
 *
 * Built from each slot's day, time and zone ONLY — `Pick` says so in the type, and the tests
 * assert no event title, venue or reason text reaches the string. The slots are one per line,
 * prefixed "- ", so the assistant lists them rather than paraphrasing a time into something he
 * did not offer, and it is told not to add others or claim anything is booked: this is an offer,
 * and nothing is on his calendar until he confirms one.
 *
 * Bounded: slots are dropped from the end until the whole instruction fits the engine's limit.
 * Returns null when no slot fits (or none were given), so a caller cannot send an empty offer.
 */
export function buildOfferInstruction(
  slots: Pick<Slot, "dayKey" | "weekday" | "start" | "end" | "zone" | "fallback">[],
  duration: number,
): { instruction: string; offered: number } | null {
  const head = `Reply offering a ${duration}-minute chat at one of these times, and ask which suits them best (Pacific Time):`;
  const tail =
    "Offer only these times, exactly as written. Do not suggest other times, and do not say anything is booked or confirmed.";
  for (let n = slots.length; n > 0; n--) {
    const lines = slots.slice(0, n).map((s) => `- ${slotLine(s)}${s.fallback ? " (evening)" : ""}`);
    const instruction = [head, ...lines, tail].join("\n");
    if (bytes(instruction) <= MAX_INSTRUCTION_BYTES) return { instruction, offered: n };
  }
  return null;
}

