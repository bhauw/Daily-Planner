/*
 * Finding a meeting time in an email, so it can be offered for the calendar.
 *
 * LOCAL AND DETERMINISTIC. This reads the text already on screen and sends it nowhere — a
 * booking offer must not be the thing that quietly ships a body to a model. It only ever
 * PROPOSES: a found time opens the scheduler prefilled, and he confirms or edits it there.
 *
 * It is deliberately narrow. It recognises the ways people actually write a meeting time in
 * mail — "Thursday at 2pm", "Sept 25, 14:30–15:00", "tomorrow 10am", "2:30 pm on Friday" — and
 * nothing cleverer. A missed time costs one click on "Add to calendar…"; a wrongly found one
 * puts a plausible, wrong event in front of him, which is the worse failure.
 */

export interface MeetingTime {
  /** What the email said, as found — shown so he can see what it was read from. */
  source: string;
  start: Date;
  end: Date;
  /** False when only a day was found; the time is then a placeholder to edit. */
  hasTime: boolean;
}

const WEEKDAYS: Record<string, number> = {
  sun: 0, sunday: 0, mon: 1, monday: 1, tue: 2, tues: 2, tuesday: 2, wed: 3, wednesday: 3,
  thu: 4, thur: 4, thurs: 4, thursday: 4, fri: 5, friday: 5, sat: 6, saturday: 6,
};

const MONTHS: Record<string, number> = {
  jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3, may: 4,
  jun: 5, june: 5, jul: 6, july: 6, aug: 7, august: 7, sep: 8, sept: 8, september: 8,
  oct: 9, october: 9, nov: 10, november: 10, dec: 11, december: 11,
};

const WEEKDAY = "(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)";
const MONTH = "(january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)";
const ORD = "(?:st|nd|rd|th)?";
const TIME = "(\\d{1,2})(?::(\\d{2}))?\\s*(a\\.?m\\.?|p\\.?m\\.?)|(\\d{1,2}):(\\d{2})|(noon|midday)";

/** How far apart a day and a time may sit and still be read as one appointment. */
const PAIR_DISTANCE = 40;
/** A found time with no stated end is booked for this long; the scheduler lets him change it. */
export const DEFAULT_MINUTES = 30;
const MAX_RESULTS = 3;

interface Found<T> {
  index: number;
  end: number;
  text: string;
  value: T;
}

interface DayValue {
  /** Days from the reference day, or an absolute date. */
  resolve: (reference: Date) => Date;
  specific: boolean;
}

interface TimeValue {
  startMin: number;
  endMin: number | null;
}

export function findMeetingTimes(text: string, reference: Date, now: Date = new Date()): MeetingTime[] {
  const days = findDays(text);
  const times = findTimes(text);

  const pairs: { day: Found<DayValue>; time: Found<TimeValue> | null }[] = [];
  const usedTimes = new Set<Found<TimeValue>>();

  for (const day of days) {
    const time = nearest(day, times, usedTimes);
    if (time) usedTimes.add(time);
    pairs.push({ day, time });
  }

  // One day and one time anywhere in the message are one appointment, however far apart —
  // "Interview Thursday" in the subject, "Can you do 14:30?" in the body.
  const lonelyTimes = times.filter((t) => !usedTimes.has(t));
  const unpaired = pairs.filter((p) => !p.time);
  if (unpaired.length === 1 && lonelyTimes.length === 1 && pairs.length === 1) {
    unpaired[0].time = lonelyTimes[0];
  }

  const out: MeetingTime[] = [];
  for (const { day, time } of pairs) {
    const date = day.value.resolve(startOfDay(reference));
    const start = new Date(date);
    const hasTime = time != null;
    start.setHours(0, time ? time.value.startMin : 9 * 60, 0, 0);
    const endMin = time?.value.endMin;
    const end =
      endMin != null && endMin > (time?.value.startMin ?? 0)
        ? withMinutes(date, endMin)
        : new Date(start.getTime() + DEFAULT_MINUTES * 60_000);
    // Nothing is offered for a time already gone: booking the past is not a thing to suggest.
    if (end.getTime() <= now.getTime()) continue;
    if (out.some((m) => m.start.getTime() === start.getTime())) continue;
    const from = Math.min(day.index, time?.index ?? day.index);
    const to = Math.max(day.end, time?.end ?? day.end);
    const source =
      time && Math.abs(time.index - day.index) <= PAIR_DISTANCE + day.text.length
        ? text.slice(from, to).replace(/\s+/g, " ").trim()
        : [day.text, time?.text].filter(Boolean).join(" · ");
    out.push({ source, start, end, hasTime });
  }
  // Timed ones first: they are the ones that can be booked without editing.
  out.sort((a, b) => Number(b.hasTime) - Number(a.hasTime) || a.start.getTime() - b.start.getTime());
  return out.slice(0, MAX_RESULTS);
}

/** An email subject as an event title: no "Re:"/"Fwd:", no trailing question mark. */
export function titleFromSubject(subject: string): string {
  const cleaned = subject
    .replace(/^\s*((re|fw|fwd)\s*:\s*)+/i, "")
    .replace(/[?!.\s]+$/, "")
    .trim();
  return cleaned || "Meeting";
}

// ---------------------------------------------------------------------------------------------

function findDays(text: string): Found<DayValue>[] {
  const found: Found<DayValue>[] = [];
  const add = (m: RegExpExecArray, value: DayValue) =>
    found.push({ index: m.index, end: m.index + m[0].length, text: m[0], value });
  // "I sat 3 exams", "you may 5 times": a short day or month name counts only capitalised,
  // which is how mail writes them. Full names are unambiguous in any case.
  const prose = (word: string) => (word.length <= 4 || word.toLowerCase() === "may") && word[0] === word[0].toLowerCase();

  // "September 25", "Sept 25th, 2026"
  for (const m of matches(text, `\\b${MONTH}\\.?\\s+(\\d{1,2})${ORD}\\b(?:,?\\s+(\\d{4}))?`)) {
    if (prose(m[1])) continue;
    const month = MONTHS[m[1].toLowerCase()];
    const day = Number(m[2]);
    const year = m[3] ? Number(m[3]) : null;
    if (day >= 1 && day <= 31) add(m, { resolve: (ref) => absolute(ref, month, day, year), specific: true });
  }
  // "25 September", "25th of Sept"
  for (const m of matches(text, `\\b(\\d{1,2})${ORD}\\s+(?:of\\s+)?${MONTH}\\b(?:,?\\s+(\\d{4}))?`)) {
    if (prose(m[2])) continue;
    const day = Number(m[1]);
    const month = MONTHS[m[2].toLowerCase()];
    const year = m[3] ? Number(m[3]) : null;
    if (day >= 1 && day <= 31) add(m, { resolve: (ref) => absolute(ref, month, day, year), specific: true });
  }
  // "2026-09-25"
  for (const m of matches(text, `\\b(\\d{4})-(\\d{2})-(\\d{2})\\b`)) {
    const [y, mo, d] = [Number(m[1]), Number(m[2]) - 1, Number(m[3])];
    if (mo >= 0 && mo < 12 && d >= 1 && d <= 31) add(m, { resolve: () => new Date(y, mo, d), specific: true });
  }
  // "Thursday", "next Thu"
  for (const m of matches(text, `\\b(?:(?:this|next|on)\\s+)?${WEEKDAY}\\b\\.?`)) {
    if (prose(m[1])) continue;
    const weekday = WEEKDAYS[m[1].toLowerCase()];
    add(m, { resolve: (ref) => nextWeekday(ref, weekday), specific: false });
  }
  for (const m of matches(text, `\\b(today|tonight|tomorrow)\\b`)) {
    const offset = m[1].toLowerCase() === "tomorrow" ? 1 : 0;
    add(m, { resolve: (ref) => addDays(ref, offset), specific: false });
  }

  // "Thursday, Sept 25" is one day said twice. Keep the specific half, drop the weekday.
  found.sort((a, b) => a.index - b.index);
  const merged: Found<DayValue>[] = [];
  for (const day of found) {
    const prev = merged[merged.length - 1];
    if (prev && day.index - prev.end <= 3) {
      if (!prev.value.specific && day.value.specific) {
        merged[merged.length - 1] = { ...day, index: prev.index, text: text.slice(prev.index, day.end) };
        continue;
      }
      if (prev.value.specific && !day.value.specific) continue;
    }
    // Overlapping matches (a month name inside a longer date) keep the first.
    if (prev && day.index < prev.end) continue;
    merged.push(day);
  }
  return merged;
}

function findTimes(text: string): Found<TimeValue>[] {
  const found: Found<TimeValue>[] = [];
  const range = new RegExp(`(?:${TIME})(?:\\s*(?:-|–|—|to|until)\\s*(?:${TIME}))?`, "gi");
  for (const m of text.matchAll(range)) {
    const index = m.index ?? 0;
    const first = minutes(m.slice(1, 7));
    if (first == null) continue;
    let second = m[7] != null || m[10] != null || m[12] != null ? minutes(m.slice(7, 13)) : null;
    let start = first.value;
    // "2-3pm": the first half borrows the second's meridiem.
    if (second && first.meridiem == null && second.meridiem === "pm" && start < 12 * 60) start += 12 * 60;
    if (second && second.value <= start) second = null;
    // A bare "10:00" that is really a price or a score is rare in mail; a bare "3:00" is almost
    // always the afternoon. Before 8 without a meridiem reads as pm.
    if (first.meridiem == null && !first.twentyFour && start < 8 * 60) start += 12 * 60;
    found.push({ index, end: index + m[0].length, text: m[0], value: { startMin: start, endMin: second?.value ?? null } });
  }
  return found;
}

function minutes(
  groups: (string | undefined)[],
): { value: number; meridiem: "am" | "pm" | null; twentyFour: boolean } | null {
  const [h12, m12, meridiem, h24, m24, noon] = groups;
  if (noon) return { value: 12 * 60, meridiem: "pm", twentyFour: false };
  if (h12 != null && meridiem) {
    let h = Number(h12);
    const m = m12 ? Number(m12) : 0;
    if (h < 1 || h > 12 || m > 59) return null;
    const pm = meridiem.toLowerCase().startsWith("p");
    if (h === 12) h = 0;
    return { value: (h + (pm ? 12 : 0)) * 60 + m, meridiem: pm ? "pm" : "am", twentyFour: false };
  }
  if (h24 != null && m24 != null) {
    const h = Number(h24);
    const m = Number(m24);
    if (h > 23 || m > 59) return null;
    return { value: h * 60 + m, meridiem: null, twentyFour: h >= 13 || h24.length === 2 && h24.startsWith("0") };
  }
  return null;
}

function nearest(
  day: Found<DayValue>,
  times: Found<TimeValue>[],
  used: Set<Found<TimeValue>>,
): Found<TimeValue> | null {
  let best: Found<TimeValue> | null = null;
  let bestGap = Infinity;
  for (const time of times) {
    if (used.has(time)) continue;
    const gap = time.index >= day.end ? time.index - day.end : day.index - time.end;
    if (gap >= 0 && gap <= PAIR_DISTANCE && gap < bestGap) {
      best = time;
      bestGap = gap;
    }
  }
  return best;
}

function matches(text: string, pattern: string): RegExpExecArray[] {
  return [...text.matchAll(new RegExp(pattern, "gi"))] as RegExpExecArray[];
}

function startOfDay(d: Date): Date {
  const out = new Date(d);
  out.setHours(0, 0, 0, 0);
  return out;
}

function addDays(d: Date, days: number): Date {
  const out = new Date(d);
  out.setDate(out.getDate() + days);
  return out;
}

function withMinutes(day: Date, mins: number): Date {
  const out = new Date(day);
  out.setHours(0, mins, 0, 0);
  return out;
}

/** The next such weekday AFTER the reference day — "Thursday" said on a Thursday is next week. */
function nextWeekday(reference: Date, weekday: number): Date {
  const ahead = (weekday - reference.getDay() + 7) % 7 || 7;
  return addDays(reference, ahead);
}

/**
 * A month and day without a year. Within the last half-year it is a date that has PASSED
 * ("that was on September 1") and is left in the past to be filtered out; further back it is
 * next year's ("January 10" written in October).
 */
function absolute(reference: Date, month: number, day: number, year: number | null): Date {
  if (year != null) return new Date(year, month, day);
  const candidate = new Date(reference.getFullYear(), month, day);
  const halfYear = 183 * 24 * 60 * 60 * 1000;
  if (candidate >= reference || reference.getTime() - candidate.getTime() < halfYear) return candidate;
  return new Date(reference.getFullYear() + 1, month, day);
}
