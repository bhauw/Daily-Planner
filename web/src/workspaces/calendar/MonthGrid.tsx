/*
 * MonthGrid — a compact month where each day carries a per-category density bar
 * so an overloaded day is visible at a glance.
 *
 * dataviz notes (skill invoked before this markup):
 *  - Form: this is a per-day magnitude/density encoding, not a chart with axes.
 *    Segments are CATEGORICAL by category (identity), assigned in a fixed order,
 *    never cycled — colour follows the entity, never its rank.
 *  - Never colour-alone: every cell states its event count (mono) and a load word
 *    ("Light/Busy/Heavy") in text, and the whole bar has an accessible summary.
 *    The category legend lives in the Day view's side panel.
 *  - 2px surface gap between segments (in calendar.css) so adjacent fills read as
 *    separate magnitudes. The bar itself is aria-hidden — its meaning is repeated
 *    in the cell's visible text and the button's accessible name.
 */

import { useMemo } from "react";
import type { PlannerEvent } from "../contract";
import { presentationFor } from "../contract";
import { addDays, partsOfKey, weekdayShort } from "./tz";
import { intervalOnDay } from "./scheduling";

interface MonthGridProps {
  anchor: string;
  planning: PlannerEvent[];
  todayKey: string;
  onPickDay: (key: string) => void;
}

const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WEEKDAY_INDEX = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const FULL_WEEKDAY: Record<string, string> = {
  Sun: "Sunday",
  Mon: "Monday",
  Tue: "Tuesday",
  Wed: "Wednesday",
  Thu: "Thursday",
  Fri: "Friday",
  Sat: "Saturday",
};

// Fixed category rank so segment order never depends on the data's arrival order.
const CATEGORY_RANK: Record<string, number> = { school: 0, career: 1, finance: 2, personal: 3, other: 4 };

const NORMAL_WINDOW_MIN = 9 * 60; // a fully-committed 9-6 weekday = "Heavy"

interface Segment {
  colorVar: string;
  label: string;
  minutes: number;
}

interface DayCell {
  key: string;
  inMonth: boolean;
  count: number;
  committed: number;
  segments: Segment[];
}

function segmentsFor(events: PlannerEvent[], key: string): { segments: Segment[]; committed: number; count: number } {
  const byColor = new Map<string, Segment & { rank: number }>();
  let committed = 0;
  for (const e of events) {
    const iv = intervalOnDay(e, key);
    const mins = iv ? Math.max(20, iv.end - iv.start) : 20;
    committed += mins;
    const p = presentationFor(e);
    const existing = byColor.get(p.colorVar);
    if (existing) existing.minutes += mins;
    else byColor.set(p.colorVar, { colorVar: p.colorVar, label: p.label, minutes: mins, rank: CATEGORY_RANK[e.category] ?? 5 });
  }
  const segments = [...byColor.values()].sort((a, b) => a.rank - b.rank).map(({ colorVar, label, minutes }) => ({ colorVar, label, minutes }));
  return { segments, committed, count: events.length };
}

function loadWord(committed: number): { word: string; heavy: boolean } {
  const ratio = committed / NORMAL_WINDOW_MIN;
  if (ratio >= 0.66) return { word: "Heavy", heavy: true };
  if (ratio >= 0.33) return { word: "Busy", heavy: false };
  if (committed > 0) return { word: "Light", heavy: false };
  return { word: "Clear", heavy: false };
}

export function MonthGrid({ anchor, planning, todayKey, onPickDay }: MonthGridProps) {
  const { y, m } = partsOfKey(anchor);
  const first = `${y}-${String(m).padStart(2, "0")}-01`;

  const cells = useMemo<DayCell[]>(() => {
    const pad = WEEKDAY_INDEX.indexOf(weekdayShort(new Date(`${first}T12:00:00Z`).toISOString()));
    const gridStart = addDays(first, -(pad < 0 ? 0 : pad));
    return Array.from({ length: 42 }, (_, i) => {
      const key = addDays(gridStart, i);
      // Every event that touches the day, counted for its part on that day — a red-eye that
      // lands Wednesday morning is on Wednesday too.
      const onDay = planning.filter((e) => intervalOnDay(e, key) != null);
      const { segments, committed, count } = segmentsFor(onDay, key);
      return { key, inMonth: partsOfKey(key).m === m, count, committed, segments };
    });
  }, [first, m, planning]);

  return (
    <div className="month">
      <div className="month__dow" aria-hidden="true">
        {DOW.map((d) => (
          <span key={d}>{d}</span>
        ))}
      </div>
      <div className="month__grid" role="grid" aria-label="Month">
        {cells.map((cell) => {
          const { key, inMonth, count, committed, segments } = cell;
          const { m: cm, d: cd } = partsOfKey(key);
          const wd = weekdayShort(new Date(`${key}T12:00:00Z`).toISOString());
          const { word, heavy } = loadWord(committed);
          const isToday = key === todayKey;
          const summary =
            count === 0
              ? `${FULL_WEEKDAY[wd]} ${MONTH_NAMES[cm - 1]} ${cd}, clear`
              : `${FULL_WEEKDAY[wd]} ${MONTH_NAMES[cm - 1]} ${cd}, ${count} ${count === 1 ? "event" : "events"}, ${word} — ${segments
                  .map((s) => `${s.label} ${s.minutes} min`)
                  .join(", ")}`;
          return (
            <button
              key={key}
              type="button"
              role="gridcell"
              className={["mcell", inMonth ? "" : "mcell--out", isToday ? "mcell--today" : ""].filter(Boolean).join(" ")}
              aria-label={summary}
              aria-current={isToday ? "date" : undefined}
              onClick={() => onPickDay(key)}
            >
              <div className="mcell__top">
                <span className="num mcell__date">{cd}</span>
                {count > 0 && (
                  <span className="num mcell__count" aria-hidden="true">
                    {count}
                  </span>
                )}
              </div>
              {segments.length > 0 && (
                <div className="density" aria-hidden="true">
                  {segments.map((s, i) => (
                    <span
                      key={i}
                      className="density__seg"
                      style={{ background: s.colorVar, flexGrow: Math.max(1, s.minutes) }}
                    />
                  ))}
                </div>
              )}
              <span className={["mcell__load", heavy ? "mcell__load--high" : ""].filter(Boolean).join(" ")} aria-hidden="true">
                {count > 0 ? word : ""}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
