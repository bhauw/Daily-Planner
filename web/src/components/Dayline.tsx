/*
 * Dayline — the signature element. A mono time gutter (tabular figures so it
 * aligns), category-coloured blocks with a left border, flexible blocks marked
 * in their subtitle, transit buffers appended when present, dashed free slots
 * for open time, and the workload PressureBar underneath.
 *
 * It derives everything it can from the schedule so nothing is hardcoded:
 * duration from start/end, "flexible" from deadline-kind blocks, free gaps from
 * the spaces between blocks, and the pressure value from committed minutes over
 * the planning window.
 *
 * Shared component: workspaces reuse this rather than re-drawing a timeline.
 */

import type { PlannerEvent } from "../api/client";
import { presentationFor } from "../lib/category";
import { durationMinutes, formatTime } from "../lib/format";
import { PressureBar, levelFor } from "./PressureBar";
import "./dayline.css";

interface DaylineProps {
  events: PlannerEvent[];
  /** planning window bounds in minutes-from-midnight; default 09:00–21:00. */
  windowStart?: number;
  windowEnd?: number;
}

interface BlockRow {
  kind: "block";
  event: PlannerEvent;
  time: string;
  subtitle: string;
  colorVar: string;
  flexible: boolean;
}
interface FreeRow {
  kind: "free";
  time: string;
  label: string;
}
type Row = BlockRow | FreeRow;

function minutesOfDay(iso: string): number | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  // Use the Vancouver wall-clock hour/minute for gutter placement.
  const parts = new Intl.DateTimeFormat("en-CA", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "America/Vancouver",
  }).formatToParts(d);
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? "0");
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  return h * 60 + m;
}

function fromMinutes(mins: number): string {
  const h = Math.floor(mins / 60)
    .toString()
    .padStart(2, "0");
  const m = (mins % 60).toString().padStart(2, "0");
  return `${h}:${m}`;
}

function buildRows(events: PlannerEvent[], windowEnd: number): Row[] {
  const sorted = [...events].sort((a, b) => a.start.localeCompare(b.start));
  const rows: Row[] = [];

  sorted.forEach((event, i) => {
    const p = presentationFor(event);
    const mins = durationMinutes(event.start, event.end);
    const flexible = event.kind === "deadline";
    const bits: string[] = [];
    if (event.location) bits.push(event.location);
    if (mins != null) bits.push(`${mins} min`);
    if (flexible) bits.push("flexible · movable");

    rows.push({
      kind: "block",
      event,
      time: formatTime(event.start),
      subtitle: bits.join(" · "),
      colorVar: p.colorVar,
      flexible,
    });

    // Insert a free slot when the gap to the next block is >= 60 min.
    const next = sorted[i + 1];
    if (next) {
      const end = event.end ? minutesOfDay(event.end) : minutesOfDay(event.start);
      const nextStart = minutesOfDay(next.start);
      if (end != null && nextStart != null && nextStart - end >= 60) {
        rows.push({ kind: "free", time: formatTime(event.end ?? event.start), label: `Free until ${formatTime(next.start)}` });
      }
    } else {
      // Trailing free time from the last block to the end of the window.
      const end = event.end ? minutesOfDay(event.end) : minutesOfDay(event.start);
      if (end != null && windowEnd - end >= 60) {
        rows.push({ kind: "free", time: formatTime(event.end ?? event.start), label: `Free until ${fromMinutes(windowEnd)}` });
      }
    }
  });

  return rows;
}

function computePressure(events: PlannerEvent[], windowStart: number, windowEnd: number) {
  const window = Math.max(1, windowEnd - windowStart);
  let committed = 0;
  const starts: number[] = [];
  const ends: number[] = [];
  for (const e of events) {
    const s = minutesOfDay(e.start);
    const en = e.end ? minutesOfDay(e.end) : s != null ? s + 30 : null;
    if (s != null && en != null) {
      committed += Math.max(0, en - s);
      starts.push(s);
      ends.push(en);
    }
  }
  const order = starts.map((s, i) => ({ s, e: ends[i] })).sort((a, b) => a.s - b.s);
  let backToBack = 0;
  for (let i = 1; i < order.length; i++) {
    if (order[i].s - order[i - 1].e < 15) backToBack++;
  }
  const value = Math.min(1, committed / window);
  return { value, backToBack, count: events.length };
}

export function Dayline({ events, windowStart = 9 * 60, windowEnd = 21 * 60 }: DaylineProps) {
  const rows = buildRows(events, windowEnd);
  const { value, backToBack, count } = computePressure(events, windowStart, windowEnd);
  const word = levelFor(value) === "high" ? "High" : levelFor(value) === "moderate" ? "Moderate" : "Calm";
  const detail = backToBack > 0 ? `${word} · ${backToBack} back-to-back` : `${word} · ${count} blocks`;

  return (
    <div className="dayline-wrap">
      <div className="dayline" role="list" aria-label="Today's schedule">
        {rows.map((row, i) =>
          row.kind === "block" ? (
            <div
              className="slot"
              role="listitem"
              key={row.event.id}
              /* Surfaces which block a row draws, so a drop target can measure the
                 boundary between two rows without re-deriving the layout. */
              data-event-id={row.event.id}
              aria-label={`${row.time}, ${row.event.title}`}
            >
              <div className="num slot__hr">{row.time}</div>
              <div className="slot__lane">
                <div className="blk" style={{ borderColor: row.colorVar }}>
                  <div className="blk__title">{row.event.title}</div>
                  {row.subtitle && <div className="num blk__sub">{row.subtitle}</div>}
                </div>
              </div>
            </div>
          ) : (
            <div className="slot" role="listitem" key={`free-${i}`} aria-label={row.label}>
              <div className="num slot__hr">{row.time}</div>
              <div className="slot__lane">
                <div className="blk blk--free">{row.label}</div>
              </div>
            </div>
          ),
        )}
      </div>
      <PressureBar value={value} detail={detail} />
    </div>
  );
}
