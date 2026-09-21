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
  colorVar: string; // e.g. "var(--cat-school)"
}

export function presentationFor(event: Pick<PlannerEvent, "category" | "kind">): CategoryPresentation {
  if (event.kind === "extracurricular") {
    return { label: "Extracurricular", tag: "EXTRA", colorVar: "var(--cat-extracurricular)" };
  }
  if (event.category === "school" && event.kind === "deadline") {
    return { label: "School deadline", tag: "DEADLINE", colorVar: "var(--cat-deadline)" };
  }
  switch (event.category) {
    case "school":
      return { label: "School", tag: "SCHOOL", colorVar: "var(--cat-school)" };
    case "career":
      return { label: "Career", tag: "CAREER", colorVar: "var(--cat-career)" };
    case "finance":
      return { label: "Finance", tag: "FINANCE", colorVar: "var(--cat-finance)" };
    case "personal":
      return { label: "Personal", tag: "PERSONAL", colorVar: "var(--cat-personal)" };
    case "commute":
      return { label: "Commute", tag: "COMMUTE", colorVar: "var(--cat-commute)" };
    case "work":
      return { label: "Work", tag: "WORK", colorVar: "var(--cat-work)" };
    case "other":
    default:
      return { label: "Other", tag: "OTHER", colorVar: "var(--cat-other)" };
  }
}

export function colorForCategory(category: Category): string {
  return presentationFor({ category, kind: "event" }).colorVar;
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
