/*
 * WeekGrid — 7 day columns × hour rows. Category-coloured blocks positioned by
 * their real Vancouver wall-clock time, overlapping events laid side by side, and
 * a current-time indicator on today's column. Flexible (focus) blocks can be
 * dragged to propose a new time; hard commitments are fixed and, when actioned,
 * explain why instead of moving. Every block is a real <button> with a composed
 * accessible name, and the move has a keyboard equivalent (focus a flexible block,
 * then ArrowUp/ArrowDown to shift it by 15 minutes).
 */

import { useRef, useState } from "react";
import type { PlannerEvent } from "../contract";
import { presentationFor, formatTime, formatLongDay, Button } from "../contract";
import { weekdayShort, isWeekend } from "./tz";
import { isFlexible, eventInterval, intervalOnDay, STEP } from "./scheduling";
import type { Role } from "./roles";
import { whenLabel, type Proposal } from "./proposals";
import { layoutColumns, blockGeometry, WINDOW_START, WINDOW_END, PX_PER_MIN, HOUR_PX } from "./layout";
import { fmtMinutes } from "./scheduling";

interface WeekGridProps {
  weekDays: string[];
  events: PlannerEvent[];
  roleOf: (e: PlannerEvent) => Role;
  showExcluded: boolean;
  todayKey: string;
  nowMinutes: number;
  proposals: Map<string, Proposal>;
  onPropose: (event: PlannerEvent, dayKey: string, toStart: number) => void;
  /** Approve/discard straight from the ghost — proposing here and approving in Day was a round trip. */
  onApprove: (id: string) => void;
  onDiscard: (id: string) => void;
  onExplainFixed: (event: PlannerEvent) => void;
  onExplainExcluded: (event: PlannerEvent) => void;
}

const HOURS = Array.from({ length: (WINDOW_END - WINDOW_START) / 60 + 1 }, (_, i) => WINDOW_START / 60 + i);
const GRID_HEIGHT = ((WINDOW_END - WINDOW_START) / 60) * HOUR_PX;

function snap(min: number): number {
  return Math.round(min / STEP) * STEP;
}
function clampStart(toStart: number, duration: number): number {
  return Math.max(WINDOW_START, Math.min(WINDOW_END - duration, toStart));
}

export function WeekGrid({
  weekDays,
  events,
  roleOf,
  showExcluded,
  todayKey,
  nowMinutes,
  proposals,
  onPropose,
  onApprove,
  onDiscard,
  onExplainFixed,
  onExplainExcluded,
}: WeekGridProps) {
  const drag = useRef<{ id: string; dayKey: string } | null>(null);
  const [dropDay, setDropDay] = useState<string | null>(null);

  function proposeFromClientY(event: PlannerEvent, dayKey: string, clientY: number, colEl: HTMLElement) {
    const rect = colEl.getBoundingClientRect();
    const iv = eventInterval(event);
    const duration = iv ? iv.end - iv.start : 45;
    const raw = WINDOW_START + (clientY - rect.top) / PX_PER_MIN;
    onPropose(event, dayKey, clampStart(snap(raw), duration));
  }

  function keyMove(event: PlannerEvent, dayKey: string, delta: number) {
    const iv = eventInterval(event);
    if (!iv) return;
    const duration = iv.end - iv.start;
    const current = proposals.get(event.id)?.toStart ?? iv.start;
    onPropose(event, dayKey, clampStart(current + delta, duration));
  }

  return (
    <div className="week">
      <div className="week__head">
        <div className="week__corner" aria-hidden="true" />
        {weekDays.map((key) => {
          const instant = new Date(`${key}T12:00:00Z`).toISOString();
          const [, , d] = key.split("-");
          const isToday = key === todayKey;
          return (
            <div
              key={key}
              className={[
                "dayhead",
                isToday ? "dayhead--today" : "",
                isWeekend(instant) ? "dayhead--weekend" : "",
              ]
                .filter(Boolean)
                .join(" ")}
            >
              <div className="dayhead__dow">{weekdayShort(instant)}</div>
              <div className="num dayhead__date">{Number(d)}</div>
            </div>
          );
        })}
      </div>

      <div className="week__grid" style={{ height: GRID_HEIGHT }}>
        <div className="week__gutter">
          {HOURS.map((h) => (
            <div key={h} className="gutter-hr" style={{ top: (h * 60 - WINDOW_START) * PX_PER_MIN }}>
              {fmtMinutes(h * 60)}
            </div>
          ))}
        </div>

        {weekDays.map((key) => {
          const instant = new Date(`${key}T12:00:00Z`).toISOString();
          // The Vancouver calendar day of the instant, not the ISO string's prefix — a UTC "Z"
          // string after 17:00 PDT carries the NEXT day's date.
          // Every day an event touches, not only its start day: an overnight shift is on both.
          const dayEvents = events.filter((e) => intervalOnDay(e, key) != null);
          const visible = dayEvents.filter((e) => roleOf(e) === "planning" || showExcluded);
          const positioned = layoutColumns(visible, key);
          const showNow = key === todayKey && nowMinutes >= WINDOW_START && nowMinutes <= WINDOW_END;

          return (
            <div
              key={key}
              className={[
                "daycol",
                isWeekend(instant) ? "daycol--weekend" : "",
                dropDay === key ? "daycol--drop" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              onDragOver={(e) => {
                if (!drag.current) return;
                e.preventDefault();
                setDropDay(key);
              }}
              onDragLeave={() => setDropDay((d) => (d === key ? null : d))}
              onDrop={(e) => {
                const d = drag.current;
                setDropDay(null);
                if (!d) return;
                e.preventDefault();
                const ev = events.find((x) => x.id === d.id);
                if (ev) proposeFromClientY(ev, key, e.clientY, e.currentTarget);
                drag.current = null;
              }}
            >
              {HOURS.map((h) => (
                <div
                  key={h}
                  className="hourline"
                  style={{ top: (h * 60 - WINDOW_START) * PX_PER_MIN }}
                  aria-hidden="true"
                />
              ))}

              {positioned.map((pos) => {
                const ev = pos.event;
                const role = roleOf(ev);
                const p = presentationFor(ev);
                const { top, height, leftPct, widthPct } = blockGeometry(pos);
                const excluded = role === "excluded";
                const flex = !excluded && isFlexible(ev);
                const proposed = proposals.has(ev.id);
                // A short event cannot fit time + title + badge. Without this the three rows
                // compress into each other and the text visibly collides (a 30-minute block
                // rendered its title underneath its own badge). Compact blocks show the title
                // only; the full detail stays available in the day view and the aria-label.
                const tight = height < 44;
                const cls = [
                  "cal-blk",
                  excluded ? "cal-blk--excluded" : flex ? "cal-blk--flex" : "cal-blk--fixed",
                  proposed ? "cal-blk--dragging" : "",
                  tight ? "cal-blk--tight" : "",
                ]
                  .filter(Boolean)
                  .join(" ");
                // The day is in the name: five "ECONOMICS 250 Lecture, 09:00" in a row told a screen
                // reader nothing about which column it was in.
                const when = `${formatLongDay(ev.start)} ${formatTime(ev.start)}`;
                const label = excluded
                  ? `${ev.title}, ${p.label}, ${when}, excluded calendar, not counted`
                  : flex
                    ? `${ev.title}, ${p.label}, ${when}, flexible — arrow keys move it`
                    : `${ev.title}, ${p.label}, ${when}, fixed`;
                return (
                  <button
                    type="button"
                    key={ev.id}
                    className={cls}
                    style={{
                      top,
                      height,
                      left: `calc(${leftPct}% + var(--space-2))`,
                      width: `calc(${widthPct}% - var(--space-2) * 2)`,
                      borderLeftColor: excluded ? "var(--text-3)" : p.colorVar,
                    }}
                    aria-label={label}
                    draggable={flex}
                    onDragStart={(e) => {
                      if (!flex) {
                        e.preventDefault();
                        return;
                      }
                      drag.current = { id: ev.id, dayKey: key };
                      e.dataTransfer.effectAllowed = "move";
                      e.dataTransfer.setData("text/plain", ev.id);
                    }}
                    onDragEnd={() => {
                      drag.current = null;
                      setDropDay(null);
                    }}
                    onKeyDown={(e) => {
                      if (flex && (e.key === "ArrowUp" || e.key === "ArrowDown")) {
                        e.preventDefault();
                        keyMove(ev, key, e.key === "ArrowUp" ? -STEP : STEP);
                      }
                    }}
                    onClick={() => {
                      if (excluded) onExplainExcluded(ev);
                      else if (!flex) onExplainFixed(ev);
                    }}
                  >
                    <span className="num cal-blk__time">{formatTime(ev.start)}</span>
                    <span className="cal-blk__title">{ev.title}</span>
                    <span className="cal-blk__badge">
                      {excluded ? "excluded" : flex ? "movable" : p.tag.toLowerCase()}
                    </span>
                  </button>
                );
              })}

              {[...proposals.values()]
                .filter((pr) => pr.dayKey === key)
                .map((pr) => {
                  const top = (pr.toStart - WINDOW_START) * PX_PER_MIN;
                  const height = Math.max(20, pr.duration * PX_PER_MIN);
                  const to = whenLabel(pr.dayKey, pr.toStart);
                  const from = whenLabel(pr.fromDayKey, pr.fromStart);
                  return (
                    <div
                      key={`ghost-${pr.event.id}`}
                      className="cal-blk cal-blk--proposed"
                      style={{ top, height, left: "var(--space-2)", right: "var(--space-2)", width: "auto" }}
                      role="group"
                      aria-label={`Proposed: ${pr.event.title}, ${from} to ${to}, needs approval`}
                    >
                      <span className="num cal-blk__time">{pr.dayKey === pr.fromDayKey ? fmtMinutes(pr.toStart) : to}</span>
                      <span className="cal-blk__title">Proposed · {pr.event.title}</span>
                      <span className="cal-blk__ghostactions">
                        <Button variant="primary" size="sm" onClick={() => onApprove(pr.event.id)}>
                          Approve
                        </Button>
                        <Button variant="ghost" size="sm" onClick={() => onDiscard(pr.event.id)}>
                          Discard
                        </Button>
                      </span>
                    </div>
                  );
                })}

              {showNow && (
                <div className="nowline" style={{ top: (nowMinutes - WINDOW_START) * PX_PER_MIN }} aria-hidden="true" />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

