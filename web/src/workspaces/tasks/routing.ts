/*
 * Tasks routing + list metadata — pure logic, no React, no I/O.
 *
 * Two jobs live here:
 *   1. List metadata: the canonical five lists (School · Career · Finance ·
 *      Personal · General), their display order, and the colour each takes.
 *      Colour is derived ONLY from the shared category tokens via the contract —
 *      a workspace never declares a colour (see workspaces/README.md §5).
 *   2. Quick-capture routing: given raw text and the planning day, infer the
 *      target list, a due DATE (never a time), whether the task also implies a
 *      calendar block or an email, and a plain-language reason for each guess so
 *      every assumption the product makes is visible to the person.
 *
 * Google Tasks stores a due *date*, never a time. `formatDueDate` therefore
 * formats the calendar date only and can never emit a time-of-day.
 */

import type { Category } from "../contract";
import { colorForCategory, presentationFor } from "../contract";

// ---- List metadata ----------------------------------------------------------

/** The five product lists, in display order, each mapped to a category. */
const CANONICAL: { name: string; category: Category }[] = [
  { name: "School", category: "school" },
  { name: "Career", category: "career" },
  { name: "Finance", category: "finance" },
  { name: "Personal", category: "personal" },
  { name: "General", category: "other" },
];

/**
 * Colour token for a list header. Known list names map to their category token;
 * "Extracurricular" (the mock's fifth list) takes the extracurricular token.
 * Anything unrecognised falls back to the neutral "other" token. No raw hex.
 */
export function listColorVar(name: string): string {
  const key = name.trim().toLowerCase();
  if (key === "extracurricular") {
    return presentationFor({ category: "other", kind: "extracurricular" }).colorVar;
  }
  const match = CANONICAL.find((l) => l.name.toLowerCase() === key);
  return colorForCategory(match ? match.category : "other");
}

/** The category a task capture routes to when it lands in this list. */
export function categoryForList(name: string): Category {
  const key = name.trim().toLowerCase();
  if (key === "extracurricular") return "personal";
  const match = CANONICAL.find((l) => l.name.toLowerCase() === key);
  return match ? match.category : "other";
}

/**
 * Order the lists the engine returned by the canonical sequence. Unknown lists
 * keep their original relative order and sit after the known ones, so an extra
 * list never disappears — it just renders last.
 */
export function orderLists<T extends { name: string }>(lists: T[]): T[] {
  const rank = (name: string) => {
    const i = CANONICAL.findIndex((l) => l.name.toLowerCase() === name.trim().toLowerCase());
    return i === -1 ? CANONICAL.length : i;
  };
  return [...lists]
    .map((list, i) => ({ list, i }))
    .sort((a, b) => rank(a.list.name) - rank(b.list.name) || a.i - b.i)
    .map((x) => x.list);
}

// ---- Due DATE formatting (never a time) -------------------------------------

const ZONE = "America/Vancouver";
// Deliberately NO hour/minute in either formatter: a task carries a date, never
// a time-of-day.
const DUE_OPTS: Intl.DateTimeFormatOptions = { weekday: "short", month: "short", day: "numeric" };
const ZONED_FMT = new Intl.DateTimeFormat("en-CA", { ...DUE_OPTS, timeZone: ZONE });
const LOCAL_FMT = new Intl.DateTimeFormat("en-CA", DUE_OPTS);

/**
 * Format a due value as a calendar date only. Accepts a full ISO datetime or a
 * bare "YYYY-MM-DD"; in both cases only the date is ever shown. A bare date is
 * parsed as a local calendar day so it never shifts across the UTC boundary; a
 * full datetime is rendered on the Vancouver calendar. Returns null for a task
 * with no due date so the card can say "No due date" rather than guess.
 */
export function formatDueDate(due: string | null): string | null {
  if (!due) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(due)) {
    const [y, m, d] = due.split("-").map(Number);
    return LOCAL_FMT.format(new Date(y, m - 1, d));
  }
  const dt = new Date(due);
  return Number.isNaN(dt.getTime()) ? null : ZONED_FMT.format(dt);
}

// ---- Quick-capture routing --------------------------------------------------

export interface CaptureRouting {
  listName: string;
  category: Category;
  /** Suggested due DATE as "YYYY-MM-DD", or null when the text implies none. */
  due: string | null;
  /** Plain-language reason for each inference — every assumption is visible. */
  reasons: string[];
  needsCalendar: boolean;
  needsEmail: boolean;
}

const SIGNALS: { category: Category; words: string[]; because: string }[] = [
  { category: "school", words: ["assignment", "midterm", "lecture", "reading", "class", "exam", "essay", "quiz", "study", "homework", "bus ", "indg", "course"], because: "signals coursework" },
  { category: "career", words: ["interview", "resume", "résumé", "co-op", "coop", "recruiter", "networking", "coffee chat", "application", "internship", "kpmg", "deloitte", "pwc", " ey ", "star stories", "thank-you"], because: "signals recruiting" },
  { category: "finance", words: ["budget", "invoice", "tax", "reconcile", "expense", "rent", "invest", "portfolio", "statement", "pay "], because: "signals money" },
  { category: "personal", words: ["groceries", "gym", "doctor", "dentist", "birthday", "laundry", "clean", "call mom", "call home", "book "], because: "signals personal errands" },
];

const CAL_WORDS = ["meeting", "call", "chat", "appointment", "lecture", "session", "focus", "block", "review", "hour", "hours", " min", "minutes"];
const EMAIL_WORDS = ["email", "reply", "send", "message", "write to", "follow up", "follow-up", "thank-you", "note to", "respond"];

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

function parseYmd(day: string): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y, (m ?? 1) - 1, d ?? 1);
}

function toYmd(d: Date): string {
  const y = d.getFullYear();
  const m = (d.getMonth() + 1).toString().padStart(2, "0");
  const day = d.getDate().toString().padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function addDays(d: Date, n: number): Date {
  const next = new Date(d);
  next.setDate(next.getDate() + n);
  return next;
}

/** Infer a due DATE from the text, relative to the planning day. Date only. */
function inferDue(text: string, today: Date): { due: string | null; reason: string | null } {
  const t = text.toLowerCase();
  if (/\b(today|tonight)\b/.test(t)) return { due: toYmd(today), reason: `Due today — the text says “${/tonight/.test(t) ? "tonight" : "today"}”.` };
  if (/\btomorrow\b/.test(t)) return { due: toYmd(addDays(today, 1)), reason: "Due tomorrow — the text says “tomorrow”." };
  if (/\bnext week\b/.test(t)) return { due: toYmd(addDays(today, 7)), reason: "Due next week — the text says “next week”." };
  for (let i = 0; i < WEEKDAYS.length; i++) {
    if (new RegExp(`\\b${WEEKDAYS[i]}\\b`).test(t)) {
      const delta = (i - today.getDay() + 7) % 7 || 7; // next occurrence, never today
      return { due: toYmd(addDays(today, delta)), reason: `Due ${WEEKDAYS[i][0].toUpperCase()}${WEEKDAYS[i].slice(1)} — the next one after today.` };
    }
  }
  return { due: null, reason: null };
}

/**
 * Route a captured line to a list + due date, and flag whether it likely also
 * needs a calendar block or an email. Never mutates and never creates anything —
 * the result is a *proposal* the person confirms.
 */
export function routeCapture(text: string, day: string, available: string[]): CaptureRouting {
  const trimmed = text.trim();
  const lower = trimmed.toLowerCase();
  const reasons: string[] = [];

  // Category from keyword signals; default to the neutral list.
  let category: Category = "other";
  let because = "no strong signal, so it lands in the catch-all list";
  for (const sig of SIGNALS) {
    if (sig.words.some((w) => lower.includes(w))) {
      category = sig.category;
      because = sig.because;
      break;
    }
  }

  // Map the category to an actual list the engine returned.
  const listName =
    available.find((n) => categoryForList(n) === category) ??
    available[available.length - 1] ??
    "General";
  reasons.push(`Routed to ${listName} — “${firstWord(trimmed)}” ${because}.`);

  // Due date.
  const { due, reason } = inferDue(lower, parseYmd(day));
  reasons.push(reason ?? "No due date — nothing in the text names a day, so it stays undated.");

  // Follow-on signals.
  const needsCalendar = CAL_WORDS.some((w) => lower.includes(w));
  if (needsCalendar) reasons.push("May need calendar time — it reads like timed work, not a checkbox.");
  const needsEmail = EMAIL_WORDS.some((w) => lower.includes(w));
  if (needsEmail) reasons.push("May need an email — it mentions replying or sending something.");

  return { listName, category, due, reasons, needsCalendar, needsEmail };
}

function firstWord(text: string): string {
  const w = text.split(/\s+/)[0] ?? text;
  return w.length > 24 ? `${w.slice(0, 24)}…` : w;
}
