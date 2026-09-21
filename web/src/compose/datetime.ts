/*
 * Converting between a <input type="datetime-local"> value and the instant the
 * engine wants.
 *
 * The input gives "2026-09-16T09:00" with NO offset — it means whatever the
 * wall clock says, and the browser will not tell you which zone that is. The
 * engine wants an unambiguous instant. Doing that conversion with `new Date(v)`
 * uses the machine's zone, which is right by accident on this machine and wrong
 * the moment it is not, and is off by an hour across a DST boundary either way.
 *
 * So both directions go through the planner's canonical zone helpers, the same
 * ones the calendar grids use. This module is pure and separately tested
 * because an hour's drift here writes the wrong time onto a real calendar and
 * nothing downstream would question it.
 */

import { dayKey, isoAtVan, minutesOfDay, partsOfKey } from "../workspaces/calendar/tz";

const INPUT_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;

/** An instant → the "YYYY-MM-DDTHH:mm" the input expects, in the planner's zone. */
export function toLocalInput(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const minutes = minutesOfDay(iso);
  const hh = String(Math.floor(minutes / 60)).padStart(2, "0");
  const mm = String(minutes % 60).padStart(2, "0");
  return `${dayKey(iso)}T${hh}:${mm}`;
}

/** The input's wall-clock value → an unambiguous instant, or null if unusable. */
export function fromLocalInput(value: string): string | null {
  const match = INPUT_PATTERN.exec(value.trim());
  if (!match) return null;
  const [, y, m, d, hh, mm] = match;
  const year = Number(y);
  const month = Number(m);
  const day = Number(d);
  const hour = Number(hh);
  const minute = Number(mm);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return null;
  // A year outside this range is a typo, not an intention. "2062" is one keystroke from "2026",
  // and the engine's own duration bound would not catch a start AND end both mistyped.
  if (year < 2000 || year > 2100) return null;
  return isoAtVan(year, month, day, hour, minute);
}

/** Shift an input value by whole minutes, staying in wall-clock terms. */
export function addMinutesToInput(value: string, minutes: number): string {
  const match = INPUT_PATTERN.exec(value.trim());
  if (!match) return value;
  const [, y, m, d, hh, mm] = match;
  const { y: year, m: month, d: day } = partsOfKey(`${y}-${m}-${d}`);
  // Wall-clock arithmetic in UTC terms, then read back as wall clock: this deliberately does
  // NOT cross a DST boundary by an hour, because "an hour later" on the form means the clock
  // reads an hour later.
  const shifted = new Date(Date.UTC(year, month - 1, day, Number(hh), Number(mm) + minutes));
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${shifted.getUTCFullYear()}-${pad(shifted.getUTCMonth() + 1)}-${pad(shifted.getUTCDate())}` +
    `T${pad(shifted.getUTCHours())}:${pad(shifted.getUTCMinutes())}`
  );
}

/** Minutes between two input values, or null when either is unusable. */
export function minutesBetweenInputs(start: string, end: string): number | null {
  const a = fromLocalInput(start);
  const b = fromLocalInput(end);
  if (!a || !b) return null;
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60_000);
}
