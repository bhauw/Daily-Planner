/*
 * Category presentation — the single source of truth for how a PlannerEvent
 * maps to a label, a colour token, and a short tag. Ported from
 * PlannerPalette.swift with the brief's fix applied:
 *   finance is LAVENDER (--cat-finance), not career yellow.
 * (The Swift PlannerPalette.swift still returns career yellow for .finance —
 *  that bug lives outside this task's scope; flagged in the handoff note.)
 *
 * Components and workspaces MUST derive colour from here. They never hardcode a
 * category colour or read a --p-* primitive.
 */

import type { Category, EventKind, PlannerEvent } from "../api/client";

export interface CategoryPresentation {
  label: string;
  tag: string; // short uppercase tag for the meta row
  colorVar: string; // e.g. "var(--cat-school)" — the MARK: borders, chips, left rules
  /**
   * The same category as INK, for text.
   *
   * Two of the mark colours do not clear 4.5:1 as small text on the lightest surface the app
   * paints — school blue lands at 3.83:1 and personal magenta at 4.45:1 — and `.tag` renders
   * this as 10px type. Same split as `--accent` and `--accent-text`: the mark keeps the brand
   * hue, the ink is lifted until it is readable. Defaults to `colorVar` for the categories
   * that already pass, so this is never a second palette to maintain.
   */
  inkVar: string;
}

/** Ink defaults to the mark; only the two that fail contrast override it. */
function present(label: string, tag: string, colorVar: string, inkVar = colorVar): CategoryPresentation {
  return { label, tag, colorVar, inkVar };
}

export function presentationFor(event: Pick<PlannerEvent, "category" | "kind">): CategoryPresentation {
  if (event.kind === "extracurricular") {
    return present("Extracurricular", "EXTRA", "var(--cat-extracurricular)");
  }
  if (event.category === "school" && event.kind === "deadline") {
    return present("School deadline", "DEADLINE", "var(--cat-deadline)");
  }
  switch (event.category) {
    case "school":
      return present("School", "SCHOOL", "var(--cat-school)", "var(--cat-school-ink)");
    case "career":
      return present("Career", "CAREER", "var(--cat-career)");
    case "finance":
      return present("Finance", "FINANCE", "var(--cat-finance)");
    case "personal":
      return present("Personal", "PERSONAL", "var(--cat-personal)", "var(--cat-personal-ink)");
    case "commute":
      return present("Commute", "COMMUTE", "var(--cat-commute)", "var(--cat-neutral-ink)");
    case "work":
      return present("Work", "WORK", "var(--cat-work)", "var(--cat-neutral-ink)");
    case "other":
    default:
      return present("Other", "OTHER", "var(--cat-other)", "var(--cat-neutral-ink)");
  }
}

export function colorForCategory(category: Category): string {
  return presentationFor({ category, kind: "event" }).colorVar;
}

/** The category as readable text. Use this anywhere the colour IS the type. */
export function inkForCategory(category: Category): string {
  return presentationFor({ category, kind: "event" }).inkVar;
}

export function kindLabel(kind: EventKind): string {
  switch (kind) {
    case "event":
      return "event";
    case "deadline":
      return "deadline";
    case "extracurricular":
      return "extracurricular";
    case "advertisement":
      return "advertisement";
  }
}
