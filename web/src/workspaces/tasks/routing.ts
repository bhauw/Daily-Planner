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
  /** The list it routes to — "" when nothing matched and there is no neutral list to use. */
  listName: string;
  category: Category;
  /** Suggested due DATE as "YYYY-MM-DD", or null when the text implies none. */
  due: string | null;
  /** Plain-language reason for each inference — every assumption is visible. */
  reasons: string[];
  needsCalendar: boolean;
  needsEmail: boolean;
  /**
   * True when the text matched no category and no neutral list exists. The person must pick
   * one: filing it somewhere arbitrary (it used to be whichever list was last — Extracurricular)
   * is an assumption the product would be making without saying so.
   */
  needsListChoice: boolean;
}

/*
 * Keyword signals, matched as whole words. A company name or a multi-word phrase is a much
 * stronger signal than a generic word, so it weighs double: "coffee chat with Example Corp about
 * midterm prep" is a recruiting task that happens to mention a midterm, not coursework.
 */
const SIGNALS: { category: Category; words: string[]; strong?: string[]; because: string }[] = [
  { category: "school", words: ["assignment", "midterm", "lecture", "reading", "readings", "class", "exam", "essay", "quiz", "study", "homework", "bus", "indg", "course", "problem set", "tutorial"], because: "coursework" },
  { category: "career", words: ["interview", "resume", "résumé", "co-op", "coop", "recruiter", "recruiting", "networking", "coffee chat", "application", "internship", "star stories", "thank-you", "cover letter"], strong: ["kpmg", "deloitte", "pwc", "ey"], because: "recruiting" },
  { category: "finance", words: ["budget", "invoice", "tax", "taxes", "reconcile", "expense", "rent", "invest", "portfolio", "statement", "pay"], because: "money" },
  { category: "personal", words: ["groceries", "gym", "doctor", "dentist", "birthday", "laundry", "clean", "call mom", "call home", "book", "passport"], because: "a personal errand" },
];

const CAL_WORDS = ["meeting", "call", "chat", "appointment", "lecture", "session", "focus", "block", "review", "hour", "hours", "min", "minutes"];
const EMAIL_WORDS = ["email", "reply", "send", "message", "write to", "follow up", "follow-up", "thank-you", "note to", "respond"];

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const WEEKDAY_SHORT = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

function escapeRe(w: string): string {
  return w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The first whole-word occurrence of `word`, as it was typed, or null. */
function findWord(text: string, word: string): string | null {
  const m = new RegExp(`(^|[^\\p{L}\\p{N}])(${escapeRe(word)})(?=$|[^\\p{L}\\p{N}])`, "iu").exec(text);
  return m ? m[2] : null;
}

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

/** A month/day with no year: this year's, or next year's once this year's has passed. */
function nextDate(today: Date, month: number, day: number): Date | null {
  if (month < 0 || month > 11 || day < 1 || day > 31) return null;
  let d = new Date(today.getFullYear(), month, day);
  if (d.getMonth() !== month) return null; // "Feb 31"
  if (d < today) d = new Date(today.getFullYear() + 1, month, day);
  return d;
}

/** Infer a due DATE from the text, relative to the planning day. Date only. */
function inferDue(text: string, today: Date): { due: string | null; reason: string | null } {
  const t = text.toLowerCase();
  if (/\b(today|tonight)\b/.test(t)) return { due: toYmd(today), reason: `Due today — the text says “${/tonight/.test(t) ? "tonight" : "today"}”.` };
  if (/\btomorrow\b/.test(t)) return { due: toYmd(addDays(today, 1)), reason: "Due tomorrow — the text says “tomorrow”." };
  if (/\bnext week\b/.test(t)) return { due: toYmd(addDays(today, 7)), reason: "Due next week — the text says “next week”." };

  // "Sept 30", "Sep 30", "September 30", "Oct 2nd".
  const named = /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b/i.exec(text);
  if (named) {
    const d = nextDate(today, MONTHS.indexOf(named[1].toLowerCase()), Number(named[2]));
    if (d) return { due: toYmd(d), reason: `Due ${formatDueDate(toYmd(d))} — read from “${named[0]}”.` };
  }
  // "9/30" — month first, as written in Canada and the US alike for a short date.
  const numeric = /\b(\d{1,2})\/(\d{1,2})\b/.exec(text);
  if (numeric) {
    const d = nextDate(today, Number(numeric[1]) - 1, Number(numeric[2]));
    if (d) return { due: toYmd(d), reason: `Due ${formatDueDate(toYmd(d))} — read from “${numeric[0]}” as month/day.` };
  }

  for (let i = 0; i < WEEKDAYS.length; i++) {
    const hit = new RegExp(`\\b(${WEEKDAYS[i]}|${WEEKDAY_SHORT[i]})\\b`).exec(t);
    if (hit) {
      const delta = (i - today.getDay() + 7) % 7 || 7; // next occurrence, never today
      return { due: toYmd(addDays(today, delta)), reason: `Due ${WEEKDAYS[i][0].toUpperCase()}${WEEKDAYS[i].slice(1)} — the next one after today (from “${hit[1]}”).` };
    }
  }
  return { due: null, reason: null };
}

function quoteList(words: string[]): string {
  const q = words.map((w) => `“${w}”`);
  return q.length <= 1 ? q.join("") : `${q.slice(0, -1).join(", ")} and ${q[q.length - 1]}`;
}

/**
 * Route a captured line to a list + due date, and flag whether it likely also
 * needs a calendar block or an email. Never mutates and never creates anything —
 * the result is a *proposal* the person confirms.
 */
export function routeCapture(text: string, day: string, available: string[]): CaptureRouting {
  const trimmed = text.trim();
  const reasons: string[] = [];

  // Score every category, not first-match-wins: the order of this table must not decide a
  // Example Corp coffee chat is coursework because "midterm" is checked first.
  let best: { category: Category; score: number; hits: string[]; because: string } | null = null;
  for (const sig of SIGNALS) {
    const hits: string[] = [];
    let score = 0;
    for (const w of sig.words) {
      const hit = findWord(trimmed, w);
      if (hit) {
        hits.push(hit);
        score += w.includes(" ") ? 2 : 1;
      }
    }
    for (const w of sig.strong ?? []) {
      const hit = findWord(trimmed, w);
      if (hit) {
        hits.push(hit);
        score += 2;
      }
    }
    if (score > 0 && (!best || score > best.score)) best = { category: sig.category, score, hits, because: sig.because };
  }

  let category: Category = best?.category ?? "other";
  let listName: string;
  let needsListChoice = false;
  if (best) {
    listName = available.find((n) => categoryForList(n) === category) ?? "";
    if (listName) {
      reasons.push(`Routed to ${listName} — ${quoteList(best.hits)} ${best.hits.length === 1 ? "signals" : "signal"} ${best.because}.`);
    } else {
      needsListChoice = true;
      reasons.push(`No list for ${best.because} — ${quoteList(best.hits)} ${best.hits.length === 1 ? "signals" : "signal"} it, but none of your lists takes it. Pick one.`);
    }
  } else {
    // A neutral list only — never whichever list happens to be last.
    listName = available.find((n) => categoryForList(n) === "other" && n.trim().toLowerCase() !== "extracurricular") ?? "";
    if (listName) {
      reasons.push(`Routed to ${listName} — no keyword pointed anywhere, so it goes to your general list.`);
    } else {
      needsListChoice = true;
      reasons.push("No clear match — pick a list. Nothing in the text points to one, and there is no general list to fall back on.");
    }
  }
  if (!listName) category = "other";

  // Due date.
  const { due, reason } = inferDue(trimmed, parseYmd(day));
  reasons.push(reason ?? "No due date — nothing in the text names a day, so it stays undated.");

  // Follow-on signals.
  const needsCalendar = CAL_WORDS.some((w) => findWord(trimmed, w));
  if (needsCalendar) reasons.push("May need calendar time — it reads like timed work, not a checkbox.");
  const needsEmail = EMAIL_WORDS.some((w) => findWord(trimmed, w));
  if (needsEmail) reasons.push("May need an email — it mentions replying or sending something.");

  return { listName, category, due, reasons, needsCalendar, needsEmail, needsListChoice };
}
