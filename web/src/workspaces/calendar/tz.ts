/*
 * America/Vancouver time helpers — DST-correct, no fixed UTC offset anywhere.
 *
 * Display formatting is already zone-correct in ../../lib/format.ts (Intl with
 * timeZone: "America/Vancouver"). This module adds the wall-clock MATH the
 * grids and the availability finder need: minutes-from-midnight in Vancouver,
 * the local calendar day, the weekday, and building an instant from a Vancouver
 * wall-clock time. Every function derives the zone offset from Intl at the given
 * instant, so a September time gets PDT (−07:00) and a January time gets PST
 * (−08:00) automatically — the offset is never hardcoded.
 */

const ZONE = "America/Vancouver";

const PARTS = new Intl.DateTimeFormat("en-CA", {
  timeZone: ZONE,
  hour12: false,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  weekday: "short",
});

const ZONE_NAME = new Intl.DateTimeFormat("en-US", {
  timeZone: ZONE,
  timeZoneName: "short",
});

interface VanParts {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
  weekday: string; // "Mon", "Tue", …
}

function partsOf(date: Date): VanParts {
  const p = PARTS.formatToParts(date);
  const get = (t: string) => p.find((x) => x.type === t)?.value ?? "";
  return {
    year: Number(get("year")),
    month: Number(get("month")),
    day: Number(get("day")),
    hour: Number(get("hour")),
    minute: Number(get("minute")),
    weekday: get("weekday"),
  };
}

/** Vancouver's UTC offset (ms) at a given instant — from Intl, DST-aware. */
function offsetMsAt(date: Date): number {
  const p = partsOf(date);
  // The instant, re-expressed as if the Vancouver wall clock were UTC.
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, 0);
  // Round the source instant to the minute to avoid seconds drift.
  const src = Math.floor(date.getTime() / 60000) * 60000;
  return asUtc - src;
}

/** Minutes from local midnight, in Vancouver. */
export function minutesOfDay(iso: string): number {
  const p = partsOf(new Date(iso));
  return p.hour * 60 + p.minute;
}

/** Vancouver calendar day as "YYYY-MM-DD" (for grouping events by day). */
export function dayKey(iso: string): string {
  const p = partsOf(new Date(iso));
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}

/** Short weekday in Vancouver, e.g. "Mon". */
export function weekdayShort(iso: string): string {
  return partsOf(new Date(iso)).weekday;
}

export function isWeekend(iso: string): boolean {
  const w = weekdayShort(iso);
  return w === "Sat" || w === "Sun";
}

/** Short zone name at an instant, e.g. "PDT" or "PST" — proves DST handling. */
export function zoneAbbrev(iso: string): string {
  const p = ZONE_NAME.formatToParts(new Date(iso)).find((x) => x.type === "timeZoneName");
  return p?.value ?? "";
}

/**
 * Build the instant for a Vancouver wall-clock time. Derives the correct offset
 * for that date (PDT vs PST) and refines once across the DST boundary. Returns a
 * UTC ISO string — an unambiguous instant that ../../lib/format renders back in
 * Vancouver. Never assumes a fixed offset.
 */
export function isoAtVan(y: number, m: number, d: number, hh: number, mm: number): string {
  const wall = Date.UTC(y, m - 1, d, hh, mm, 0);
  let offset = offsetMsAt(new Date(wall));
  let t = wall - offset;
  offset = offsetMsAt(new Date(t));
  t = wall - offset;
  return new Date(t).toISOString();
}

/** Add days to a "YYYY-MM-DD" key, staying on calendar days (no offset math). */
export function addDays(dayKeyStr: string, delta: number): string {
  const [y, m, d] = dayKeyStr.split("-").map(Number);
  const t = Date.UTC(y, m - 1, d + delta);
  const dt = new Date(t);
  return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, "0")}-${String(
    dt.getUTCDate(),
  ).padStart(2, "0")}`;
}

/** Split a "YYYY-MM-DD" key into numbers. */
export function partsOfKey(dayKeyStr: string): { y: number; m: number; d: number } {
  const [y, m, d] = dayKeyStr.split("-").map(Number);
  return { y, m, d };
}
