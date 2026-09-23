/*
 * ThreeColumn — the "Today" surface: Priority · Today · Assistant. Reproduces
 * the approved Option A layout: two equal fluid columns and a fixed-width
 * assistant dock on the right. (The old SwiftUI ThreeColumnLayoutPolicy used
 * equal 0.27 side columns; Option A — the reviewed design — sets Priority and
 * Today equal with a fixed assistant, so we follow Option A and keep a 260px
 * floor on the fluid columns.)
 */

import type { Draft, PlannerEvent, Preview, TasksResponse } from "../api/client";
import { ColumnHeader, EmptyState } from "../components/Column";
import { Dayline } from "../components/Dayline";
import { EventRow } from "../components/EventRow";
import { DraftCard } from "../components/DraftCard";
import { Button } from "../components/Button";
import { PlanIcon, TodayIcon } from "./icons";
import { formatLongDay, formatTime } from "../lib/format";
import { TodayPrep } from "../prep/TodayPrep";
import { selectPrepEvent, usePrepSession } from "../prep/session";
import "./three-column.css";

interface ThreeColumnProps {
  preview: Preview;
  drafts: Draft[];
  /** For the prep card: the week (yesterday's chat may still be owed a thank-you) and tasks. */
  weekEvents?: PlannerEvent[] | null;
  tasks?: TasksResponse | null;
  /** Opens Plan my day. Absent (a detached window, a test) and the button is not offered. */
  onPlan?: () => void;
  /** Today's scan slots from /api/settings, as ISO instants. Null when settings were unread. */
  scanTimes?: string[] | null;
  /** Injected in tests; the real clock otherwise. */
  now?: Date;
}

/**
 * The line under the assistant header, from the engine's own scan slots.
 *
 * It was the literal "Next scan 21:00 · Vancouver" — shown at 22:00, and bound to go on saying
 * 21:00 whatever the schedule was set to. Null (no line) when the settings could not be read:
 * a made-up time is the thing this replaces.
 */
export function nextScanLabel(scanTimes: string[] | null | undefined, now: Date): string | null {
  if (!scanTimes || scanTimes.length === 0) return null;
  const upcoming = scanTimes
    .map((iso) => ({ iso, t: new Date(iso).getTime() }))
    .filter(({ t }) => !Number.isNaN(t) && t > now.getTime())
    .sort((a, b) => a.t - b.t)[0];
  return upcoming ? `Next scan ${formatTime(upcoming.iso)} · Vancouver` : "No more scans today";
}

function itemCount(n: number): string {
  return `${n} ${n === 1 ? "item" : "items"}`;
}

/*
 * A block the plan (or he) already put on the day. Matches the titles Plan my day writes and the
 * "Focus — …" blocks already on his calendar, so the offer to plan steps back once there are some.
 */
function hasFocusBlock(preview: Preview): boolean {
  return preview.schedule.some((e) => /^focus\b/i.test(e.title.trim()));
}

export function ThreeColumn({
  preview,
  drafts,
  weekEvents = null,
  tasks = null,
  onPlan,
  scanTimes,
  now,
}: ThreeColumnProps) {
  const prepSession = usePrepSession();
  const nextScan = nextScanLabel(scanTimes, now ?? new Date());
  const planned = hasFocusBlock(preview);
  return (
    <div className="threecol">
      {/*
       * Home had no page <h1> at all — its outermost heading was ColumnHeader's h3, so the
       * outline skipped from nothing straight into a column header (axe page-has-heading-one).
       * sr-only: the three panes' own eyebrows (Priority/Today/Assistant) already fill the
       * space a visible page title would take, so this states the page's name without adding
       * a fourth title on screen.
       */}
      <h1 className="sr-only">Today</h1>
      <section className="threecol__pane scroll-y" aria-label="Priority queue">
        <ColumnHeader eyebrow="Priority" title="Up next" count={itemCount(preview.queue.length)} />
        <div className="threecol__hairline" />
        {preview.queue.length === 0 ? (
          <EmptyState
            icon={<TodayIcon width={22} height={22} />}
            title="No planning items"
            detail="Choose a planning calendar in Settings, then refresh to see what's next."
          />
        ) : (
          <div role="list">
            {preview.queue.map((event) => (
              <EventRow key={event.id} event={event} />
            ))}
          </div>
        )}
      </section>

      <section className="threecol__pane scroll-y" aria-label="Today's schedule">
        <ColumnHeader
          eyebrow="Today"
          title={formatLongDay(`${preview.day}T09:00:00-07:00`)}
          count={`${preview.schedule.length} ${preview.schedule.length === 1 ? "block" : "blocks"}`}
        />
        {onPlan && (
          // Always offered — a day can be re-planned — but it only asks for attention (primary)
          // while nothing is planned yet.
          <div className="threecol__plan">
            <Button size="sm" variant={planned ? "default" : "primary"} icon={<PlanIcon />} onClick={onPlan}>
              Plan my day
            </Button>
            {!planned && <span className="threecol__plannote">No focus time blocked yet.</span>}
          </div>
        )}
        <div className="threecol__hairline" />
        {preview.schedule.length === 0 ? (
          <EmptyState
            icon={<TodayIcon width={22} height={22} />}
            title="Your day is clear"
            detail="Planning-calendar items appear here after the next scan."
          />
        ) : (
          <Dayline
            events={preview.schedule}
            onSelect={(event) => selectPrepEvent(event.id)}
            selectedId={prepSession.selectedId}
          />
        )}
        <TodayPrep schedule={preview.schedule} weekEvents={weekEvents} drafts={drafts} tasks={tasks} />
      </section>

      <aside className="threecol__pane threecol__assistant scroll-y" aria-label="Assistant">
        <ColumnHeader
          eyebrow="Assistant"
          title={drafts.length > 0 ? "Ready" : "Idle"}
          count={`${drafts.length} ${drafts.length === 1 ? "draft" : "drafts"}`}
        />
        <div className="threecol__hairline" />
        <div className="astat">
          <div className="astat__row">
            <span className="astat__ic" aria-hidden="true">✓</span>
            <span>Nothing sent without your approval.</span>
          </div>
          {nextScan && (
            <div className="astat__row">
              <span className="astat__ic" aria-hidden="true">◷</span>
              <span>{nextScan}</span>
            </div>
          )}
          {drafts.length === 0 ? (
            <EmptyState
              title="No drafts waiting"
              detail="When the assistant prepares a reply or a calendar bundle, it will wait here for your review."
            />
          ) : (
            drafts.map((draft, i) => <DraftCard key={draft.id} draft={draft} quiet={i > 0} />)
          )}
        </div>
      </aside>
    </div>
  );
}
