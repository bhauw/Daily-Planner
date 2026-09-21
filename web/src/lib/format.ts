/*
 * Time and day formatting. The planner's canonical zone is America/Vancouver
 * (matches PlannerFormatting.swift), so times render consistently regardless of
 * the machine's zone. All numeric output is meant to be shown in the mono face.
 */

const ZONE = "America/Vancouver";

const TIME = new Intl.DateTimeFormat("en-CA", {
  hour: "numeric",
  minute: "2-digit",
  hour12: false,
  timeZone: ZONE,
});

const LONG_DAY = new Intl.DateTimeFormat("en-CA", {
  weekday: "long",
  month: "short",
  day: "numeric",
  timeZone: ZONE,
});

function parse(iso: string): Date | null {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function formatTime(iso: string | null): string {
  if (!iso) return "";
  const d = parse(iso);
  return d ? TIME.format(d) : "";
}

export function formatRange(startIso: string, endIso: string | null): string {
  const start = formatTime(startIso);
  const end = endIso ? formatTime(endIso) : "";
  return end ? `${start}–${end}` : start;
}

export function formatLongDay(iso: string): string {
  const d = parse(iso);
  return d ? LONG_DAY.format(d) : iso;
}

export function durationMinutes(startIso: string, endIso: string | null): number | null {
  if (!endIso) return null;
  const s = parse(startIso);
  const e = parse(endIso);
  if (!s || !e) return null;
  return Math.max(0, Math.round((e.getTime() - s.getTime()) / 60000));
}
