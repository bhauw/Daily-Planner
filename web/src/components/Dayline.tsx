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
import { PressureBar } from "./PressureBar";
import { workloadFor } from "../lib/workload";
import "./dayline.css";

interface DaylineProps {
  events: PlannerEvent[];
  /**
   * Drawn window bounds in minutes-from-midnight; default 09:00–21:00. The end bounds the
   * trailing "Free until" row. Workload is always read over the planning day, not this.
   */
  windowStart?: number;
  windowEnd?: number;
  /**
   * Makes each block a button that reports which event was pressed. Optional, and absent
   * everywhere but Today: Tasks' time-blocking measures these rows as drop targets, and a
   * button there would be a click target competing with the drag.
   */
  onSelect?: (event: PlannerEvent) => void;
  /** The block to show as pressed, when `onSelect` is given. */
  selectedId?: string | null;
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
  // By instant, not by string. `localeCompare` on ISO strings only orders correctly when every
  // one carries the same offset; the engine's reads say "-07:00" and a write's receipt says "Z",
  // so a block created at 16:00 sorted before a 09:00 lecture and the day read out of order.
  const at = (iso: string) => {
    const t = new Date(iso).getTime();
    return Number.isNaN(t) ? Infinity : t;
  };
  const sorted = [...events].sort((a, b) => at(a.start) - at(b.start));
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

export function Dayline({ events, windowEnd = 21 * 60, onSelect, selectedId }: DaylineProps) {
  const rows = buildRows(events, windowEnd);
  // One reading everywhere (lib/workload): the window this timeline DRAWS no longer changes it.
  const { value, detail } = workloadFor(events);

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
                {onSelect ? (
                  <button
                    type="button"
                    className="blk blk--button"
                    style={{ borderColor: row.colorVar }}
                    aria-pressed={selectedId === row.event.id}
                    onClick={() => onSelect(row.event)}
                  >
                    <span className="blk__title" style={{ display: "block" }}>{row.event.title}</span>
                    {row.subtitle && <span className="num blk__sub" style={{ display: "block" }}>{row.subtitle}</span>}
                  </button>
                ) : (
                  <div className="blk" style={{ borderColor: row.colorVar }}>
                    <div className="blk__title">{row.event.title}</div>
                    {row.subtitle && <div className="num blk__sub">{row.subtitle}</div>}
                  </div>
                )}
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
