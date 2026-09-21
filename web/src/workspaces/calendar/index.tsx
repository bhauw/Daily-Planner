/*
 * Calendar workspace mount point (task 05). The shell auto-discovers this file
 * via import.meta.glob and mounts it at /calendar (and, detached, at
 * /detach/calendar) — creating this file is what satisfies the detached-window
 * route. See ../README.md for the mounting contract.
 *
 * This root owns the cross-view state that must stay consistent across the four
 * surfaces: which calendars count (roles, fail-closed), whether excluded
 * reference calendars are shown, the reschedule proposals in flight, and the
 * active view + anchor day. Every time value is computed in America/Vancouver
 * via ./tz (offset derived from Intl at each instant — PDT/PST automatic).
 */

import { useMemo, useState } from "react";
import type { WorkspaceProps, PlannerEvent } from "../contract";
import { useAsync, EmptyState, ConnectionState, Button } from "../contract";
import { addDays, weekdayShort, partsOfKey, minutesOfDay, zoneAbbrev } from "./tz";
import {
  buildCalendarStates,
  planningEvents as planningOnly,
  roleForEvent,
  toggleRole,
  type CalendarState,
} from "./roles";
import { busyForDay, eventInterval, fmtMinutes } from "./scheduling";
import { proposalFor, type Proposal } from "./proposals";
import { WeekGrid } from "./WeekGrid";
import { MonthGrid } from "./MonthGrid";
import { DaylineDetail } from "./DaylineDetail";
import { AvailabilityFinder } from "./AvailabilityFinder";
import "./calendar.css";

type View = "week" | "month" | "day" | "availability";

const VIEWS: { id: View; label: string }[] = [
  { id: "week", label: "Week" },
  { id: "month", label: "Month" },
  { id: "day", label: "Day" },
  { id: "availability", label: "Availability" },
];

const WEEKDAY_INDEX = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function noonInstant(key: string): string {
  return new Date(`${key}T12:00:00Z`).toISOString();
}

/** The Sunday on or before a day-key, so a week is Sun..Sat. */
function weekStart(key: string): string {
  const idx = WEEKDAY_INDEX.indexOf(weekdayShort(noonInstant(key)));
  return addDays(key, -(idx < 0 ? 0 : idx));
}

function shortLabel(key: string): string {
  const { m, d } = partsOfKey(key);
  return `${MONTHS[m - 1]} ${d}`;
}

export default function CalendarWorkspace({ api, day, detached }: WorkspaceProps) {
  // `/api/week`, not `/api/preview`.
  //
  // This surface draws a week (and a month), but it was reading the one-day preview: the engine
  // states at APIContract.swift that "/api/preview is deliberately one local day", while
  // WeekResponse exists so "a client can render the week without stitching two responses
  // together". So six of the seven columns had nothing to draw but today, and the month grid
  // was a whole month rendered from a single day. The endpoint built for this screen was never
  // called by it.
  const { status, data, reload } = useAsync(async () => {
    const [preview, week, calendars] = await Promise.all([api.preview(), api.week(), api.calendars()]);
    return { preview, week, calendars: calendars.calendars };
  });

  if (status === "disconnected") return <ConnectionState onRetry={reload} />;
  if (status === "loading")
    return (
      <div className="app__loading" role="status" aria-live="polite">
        Loading your calendar…
      </div>
    );
  if (status === "error" || !data)
    return (
      <EmptyState
        title="Couldn't load your calendar"
        detail="The engine returned an unexpected response. Try again in a moment."
        action={
          <Button variant="default" size="sm" onClick={reload}>
            Try again
          </Button>
        }
      />
    );

  return (
    <CalendarBody
      weekEvents={data.week.events}
      calendarSummaries={data.calendars}
      day={day}
      detached={detached}
    />
  );
}

interface BodyProps {
  /** Every eligible event across the window, today included. */
  weekEvents: PlannerEvent[];
  calendarSummaries: { id: string; title: string; role: "planning" | "excluded" }[];
  day: string;
  detached: boolean;
}

function CalendarBody({ weekEvents, calendarSummaries, day: activeDay, detached }: BodyProps) {
  // Only real events. The previous source folded `preview.queue` in alongside the schedule,
  // which put things that are not appointments — a recruiter's email, "Midterm 2 review
  // posted" — onto the grid as timed blocks, crowding the real day with items that have no
  // duration and cannot be attended.
  const events = useMemo<PlannerEvent[]>(() => weekEvents, [weekEvents]);

  // Fail-closed calendar roles: only `planning` calendars count anywhere.
  const [states, setStates] = useState<CalendarState[]>(() => buildCalendarStates(calendarSummaries, events));
  const roleOf = useMemo(() => (e: PlannerEvent) => roleForEvent(e, states), [states]);
  const planning = useMemo(() => planningOnly(events, states), [events, states]);

  const [view, setView] = useState<View>("week");
  const [anchor, setAnchor] = useState<string>(activeDay);
  const [showExcluded, setShowExcluded] = useState(false);
  const [proposals, setProposals] = useState<Map<string, Proposal>>(new Map());
  const [accepted, setAccepted] = useState<Set<string>>(new Set());
  const [message, setMessage] = useState<string>("");

  const nowMinutes = minutesOfDay(new Date().toISOString());
  const week = useMemo(() => {
    const start = weekStart(anchor);
    return Array.from({ length: 7 }, (_, i) => addDays(start, i));
  }, [anchor]);

  function announce(text: string) {
    setMessage(text);
  }

  function onPropose(event: PlannerEvent, dayKey: string, toStart: number) {
    const iv = eventInterval(event);
    if (!iv) return;
    const duration = iv.end - iv.start;
    const busy = busyForDay(planning, dayKey);
    const p = proposalFor(event, dayKey, iv.start, toStart, duration, busy);
    setProposals((m) => new Map(m).set(event.id, p));
    setAccepted((s) => {
      if (!s.has(event.id)) return s;
      const n = new Set(s);
      n.delete(event.id);
      return n;
    });
    announce(
      p.collision
        ? `Proposed ${event.title} to ${fmtMinutes(toStart)}, but it ${p.collision.toLowerCase()}. This is a proposal — nothing was sent.`
        : `Proposed ${event.title} to ${fmtMinutes(toStart)}. This needs approval — nothing was sent.`,
    );
  }

  function onApprove(id: string) {
    const p = proposals.get(id);
    setAccepted((s) => new Set(s).add(id));
    setProposals((m) => {
      const n = new Map(m);
      n.delete(id);
      return n;
    });
    announce(
      p
        ? `Accepted ${p.event.title} locally at ${fmtMinutes(p.toStart)}. No external write was made — this round is read-only.`
        : "Accepted locally. No external write was made.",
    );
  }

  function onDiscard(id: string) {
    const p = proposals.get(id);
    setProposals((m) => {
      const n = new Map(m);
      n.delete(id);
      return n;
    });
    announce(p ? `Discarded the proposal for ${p.event.title}.` : "Proposal discarded.");
  }

  function onExplainFixed(event: PlannerEvent) {
    announce(`${event.title} is a hard conflict and can't be moved. Only flexible focus blocks can be proposed to a new time.`);
  }

  function onExplainExcluded(event: PlannerEvent) {
    announce(`${event.title} is on an excluded reference calendar. It's shown for context only and never counts toward availability, workload, or conflicts.`);
  }

  function step(delta: number) {
    if (view === "week") setAnchor((a) => addDays(a, delta * 7));
    else if (view === "day" || view === "availability") setAnchor((a) => addDays(a, delta));
    else {
      // month: jump to the first of the previous/next month
      const { y, m } = partsOfKey(anchor);
      const nm = m - 1 + delta;
      const ny = y + Math.floor(nm / 12);
      const mm = ((nm % 12) + 12) % 12;
      setAnchor(`${ny}-${String(mm + 1).padStart(2, "0")}-01`);
    }
  }

  const period =
    view === "week"
      ? `${shortLabel(week[0])} – ${shortLabel(week[6])}`
      : view === "month"
        ? `${MONTHS[partsOfKey(anchor).m - 1]} ${partsOfKey(anchor).y}`
        : shortLabel(anchor);

  const zone = zoneAbbrev(noonInstant(anchor));

  function pickDay(key: string) {
    setAnchor(key);
    setView("day");
  }

  return (
    <div className={["cal", detached ? "cal--detached" : ""].filter(Boolean).join(" ")}>
      <header className="cal__head">
        <div className="cal__titlerow">
          <div>
            <div className="cal__eyebrow">Calendar</div>
            <h1 className="cal__title">{period}</h1>
          </div>
          <span className="cal__spring" />
          <span className="cal__zone" title="Times shown in America/Vancouver">
            {zone} · America/Vancouver
          </span>
        </div>

        <div className="cal__toolbar">
          <div className="viewswitch" role="group" aria-label="Calendar view">
            {VIEWS.map((v) => (
              <button
                key={v.id}
                type="button"
                className="viewswitch__btn"
                aria-pressed={view === v.id}
                onClick={() => setView(v.id)}
              >
                {v.label}
              </button>
            ))}
          </div>

          <div className="cal__navgroup">
            <Button variant="default" size="sm" label="Previous period" icon={<span aria-hidden="true">‹</span>} onClick={() => step(-1)} />
            <Button variant="ghost" size="sm" onClick={() => setAnchor(activeDay)}>
              Today
            </Button>
            <Button variant="default" size="sm" label="Next period" icon={<span aria-hidden="true">›</span>} onClick={() => step(1)} />
          </div>

          <span className="cal__spring" />

          <label className="excluded-toggle">
            <input type="checkbox" checked={showExcluded} onChange={(e) => setShowExcluded(e.target.checked)} />
            Show excluded reference calendars
          </label>
        </div>

        {message && (
          <p className="cal__msg" role="status">
            {message}
          </p>
        )}
        <div className="cal__live" role="status" aria-live="polite">
          {message}
        </div>
      </header>

      <div className="cal__body scroll-y">
        {view === "week" && (
          <WeekGrid
            weekDays={week}
            events={events}
            roleOf={roleOf}
            showExcluded={showExcluded}
            todayKey={activeDay}
            nowMinutes={nowMinutes}
            proposals={proposals}
            onPropose={onPropose}
            onExplainFixed={onExplainFixed}
            onExplainExcluded={onExplainExcluded}
          />
        )}
        {view === "month" && (
          <MonthGrid anchor={anchor} planning={planning} todayKey={activeDay} onPickDay={pickDay} />
        )}
        {view === "day" && (
          <DaylineDetail
            dayKey={anchor}
            events={events}
            planning={planning}
            states={states}
            roleOf={roleOf}
            showExcluded={showExcluded}
            proposals={proposals}
            accepted={accepted}
            onPropose={onPropose}
            onApprove={onApprove}
            onDiscard={onDiscard}
            onToggleRole={(id) => setStates((s) => toggleRole(s, id))}
            onExplainFixed={onExplainFixed}
          />
        )}
        {view === "availability" && (
          <AvailabilityFinder fromKey={anchor} planning={planning} allEvents={events} states={states} />
        )}
      </div>
    </div>
  );
}
