/*
 * Calendar roles — fail-closed. Only calendars marked `planning` affect
 * availability, workload, conflicts, or suggestions. A calendar marked
 * `excluded` is viewable only when deliberately opened and contributes nothing;
 * an unknown source defaults to excluded.
 *
 * NOTE (contract gap, flagged in the completion note): PlannerEvent carries no
 * calendarId in the API contract, so this workspace attributes an event to a
 * calendar by matching its category to a calendar title (school→"School", …).
 * An event whose category matches no calendar has no planning home and is
 * therefore excluded by default — the fail-closed rule, made concrete.
 *
 * Role changes here are LOCAL VIEW STATE only. This round is read-only: toggling
 * a role never writes to a provider — it re-scopes what this view counts.
 */

import type { CalendarSummary, Category, PlannerEvent } from "../contract";

export type Role = "planning" | "excluded";

export interface CalendarState {
  id: string;
  title: string;
  role: Role;
  /** true when the app inferred this calendar from events, not the engine list. */
  inferred: boolean;
}

const CATEGORY_TITLES: Record<Category, string> = {
  school: "School",
  career: "Career",
  finance: "Finance",
  personal: "Personal",
  other: "Other",
  commute: "Commute",
  work: "Work",
};

function norm(s: string): string {
  return s.trim().toLowerCase();
}

/** The category a calendar title stands for, if any. */
export function categoryForTitle(title: string): Category | null {
  const key = norm(title);
  for (const [cat, t] of Object.entries(CATEGORY_TITLES) as [Category, string][]) {
    if (norm(t) === key) return cat;
  }
  return null;
}

/**
 * Build the calendar list this view manages: every calendar the engine returned,
 * plus a fail-closed `excluded` entry for any event category that has no matching
 * calendar (an unknown source defaults to excluded).
 */
export function buildCalendarStates(
  calendars: CalendarSummary[],
  events: PlannerEvent[],
): CalendarState[] {
  const states: CalendarState[] = calendars.map((c) => ({
    id: c.id,
    title: c.title,
    role: c.role,
    inferred: false,
  }));
  const known = new Set(states.map((s) => categoryForTitle(s.title)).filter(Boolean) as Category[]);
  const seen = new Set<Category>();
  for (const e of events) {
    if (known.has(e.category) || seen.has(e.category)) continue;
    seen.add(e.category);
    states.push({
      id: `inferred-${e.category}`,
      title: CATEGORY_TITLES[e.category],
      role: "excluded", // fail-closed: unknown source contributes nothing
      inferred: true,
    });
  }
  return states;
}

/** The role governing an event, resolved through its category's calendar. */
export function roleForEvent(event: PlannerEvent, states: CalendarState[]): Role {
  for (const s of states) {
    if (categoryForTitle(s.title) === event.category) return s.role;
  }
  return "excluded"; // no home calendar → excluded
}

export function isPlanning(event: PlannerEvent, states: CalendarState[]): boolean {
  return roleForEvent(event, states) === "planning";
}

/** Only the events that count: those on a planning calendar. */
export function planningEvents(events: PlannerEvent[], states: CalendarState[]): PlannerEvent[] {
  return events.filter((e) => isPlanning(e, states));
}

export function toggleRole(states: CalendarState[], id: string): CalendarState[] {
  return states.map((s) =>
    s.id === id ? { ...s, role: s.role === "planning" ? "excluded" : "planning" } : s,
  );
}
