/*
 * Workload — the one reading behind every PressureBar.
 *
 * Committed minutes over the PLANNING day (09:00–21:00), with each block clipped to it. The
 * window is fixed here rather than taken from whatever a timeline happens to draw: the
 * Calendar draws 07:00–21:00 to show the evening fallback band, and dividing by that made the
 * same day read "Calm" there and "Moderate" on Tasks and Today. What is committed does not
 * change because a view shows more empty morning.
 */

import type { PlannerEvent } from "../api/client";
import { levelFor, type PressureLevel } from "../components/PressureBar";

export const WORKLOAD_START = 9 * 60;
export const WORKLOAD_END = 21 * 60;

const HM = new Intl.DateTimeFormat("en-CA", {
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
  timeZone: "America/Vancouver",
});

function minutesOfDay(iso: string): number | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = HM.formatToParts(d);
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? "0");
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  return h * 60 + m;
}

export interface Workload {
  /** 0..1 — committed share of the planning day. */
  value: number;
  level: PressureLevel;
  word: "Calm" | "Moderate" | "High";
  backToBack: number;
  count: number;
  /** "Moderate · 4 blocks" / "High · 2 back-to-back" — the meter's text, identical everywhere. */
  detail: string;
}

const WORD: Record<PressureLevel, Workload["word"]> = { calm: "Calm", moderate: "Moderate", high: "High" };

export function workloadFor(events: PlannerEvent[]): Workload {
  const window = WORKLOAD_END - WORKLOAD_START;
  let committed = 0;
  const spans: { s: number; e: number }[] = [];
  for (const ev of events) {
    const s = minutesOfDay(ev.start);
    const en = ev.end ? minutesOfDay(ev.end) : s != null ? s + 30 : null;
    if (s == null || en == null) continue;
    committed += Math.max(0, Math.min(WORKLOAD_END, en) - Math.max(WORKLOAD_START, s));
    spans.push({ s, e: en });
  }
  spans.sort((a, b) => a.s - b.s);
  let backToBack = 0;
  for (let i = 1; i < spans.length; i++) {
    if (spans[i].s - spans[i - 1].e < 15) backToBack++;
  }
  const value = Math.min(1, committed / window);
  const level = levelFor(value);
  const word = WORD[level];
  const count = events.length;
  return {
    value,
    level,
    word,
    backToBack,
    count,
    detail: backToBack > 0 ? `${word} · ${backToBack} back-to-back` : `${word} · ${count} blocks`,
  };
}
