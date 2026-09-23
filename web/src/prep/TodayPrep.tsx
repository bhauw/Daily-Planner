/*
 * TodayPrep — the prep card's place on Today, under the day timeline.
 *
 * Three things, from quietest to loudest:
 *
 *  1. "Thank-you due" rows, one per career conversation that ended less than 48 hours ago and
 *     has not been thanked from the card this session. Computed once, from the data the shell
 *     already has, when Today renders — no timer, nothing polled.
 *  2. The card itself, for the event he pressed on the Dayline. When he has not pressed one,
 *     it shows the thank-you that is due, or else the next chat or interview today — the card
 *     he would have gone looking for.
 *  3. When he presses an event that is not a chat or an interview (a lecture), a plain note
 *     saying so, instead of a card with nothing in it.
 *
 * It lives INSIDE the Today pane, which already scrolls. It adds no scroll container of its
 * own: the column gets one scrollbar, as every surface in this app does.
 */

import { useMemo, useState } from "react";
import type { Draft, PlannerEvent, TasksResponse } from "../api/client";
import { Button } from "../components/Button";
import { detectPrep, prepPhase, thankYousDue } from "./match";
import { PrepCard, type PrepClient } from "./PrepCard";
import { selectPrepEvent, usePrepSession } from "./session";
import "./prep.css";

interface TodayPrepProps {
  /** Today's schedule — what the Dayline draws. */
  schedule: PlannerEvent[];
  /** The week, when it could be read. Null is fine: Today still has its own day. */
  weekEvents?: PlannerEvent[] | null;
  drafts: Draft[];
  tasks: TasksResponse | null;
  /** Injected for tests; otherwise read once, on mount. */
  now?: Date;
  client?: PrepClient;
}

export function TodayPrep({ schedule, weekEvents, drafts, tasks, now: fixedNow, client }: TodayPrepProps) {
  // Read once. "Computed when the app opens" — a row that appears or vanishes while he is
  // looking at it, on a timer, is the kind of motion this app does not do.
  const [openedAt] = useState(() => new Date());
  const now = fixedNow ?? openedAt;
  const session = usePrepSession();

  // Everything the shell knows about, de-duplicated by id: the week includes today.
  const events = useMemo(() => {
    const byId = new Map<string, PlannerEvent>();
    for (const e of [...schedule, ...(weekEvents ?? [])]) if (!byId.has(e.id)) byId.set(e.id, e);
    return [...byId.values()];
  }, [schedule, weekEvents]);

  const allTasks = useMemo(() => (tasks?.lists ?? []).flatMap((l) => l.items), [tasks]);
  const due = thankYousDue(events, now, session.thanked);

  const picked = session.selectedId ? events.find((e) => e.id === session.selectedId) ?? null : null;
  const fallback =
    due[0]?.prep ??
    schedule
      .map(detectPrep)
      .filter((p): p is NonNullable<typeof p> => p != null && prepPhase(p.event, now) !== "past")
      .sort((a, b) => a.event.start.localeCompare(b.event.start))[0] ??
    null;
  const pickedPrep = picked ? detectPrep(picked) : null;
  const shown = picked ? pickedPrep : fallback;

  if (due.length === 0 && !shown && !picked) return null;

  return (
    <div className="todayprep">
      {due.length > 0 && (
        <ul className="todayprep__due" aria-label="Thank-yous due">
          {due.map(({ prep, endedAgo }) => (
            <li key={prep.event.id}>
              <button
                type="button"
                className="todayprep__row"
                aria-pressed={shown?.event.id === prep.event.id}
                onClick={() => selectPrepEvent(prep.event.id)}
              >
                <span className="todayprep__dot" aria-hidden="true" />
                <span>
                  Thank-you due — {prep.label} <span className="todayprep__ago">(ended {endedAgo})</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}

      {picked && !pickedPrep ? (
        <div className="prep prep--none" role="status">
          <div className="prep__head">
            <div>
              <div className="prep__eyebrow">No prep card</div>
              <h4 className="prep__title">{picked.title}</h4>
            </div>
            <Button size="sm" variant="ghost" label="Close" icon={<span aria-hidden="true">×</span>} onClick={() => selectPrepEvent(null)} />
          </div>
          <p className="prep__empty">
            Prep cards open for coffee chats and interviews — a career event, or one whose title names the firm.
          </p>
        </div>
      ) : (
        shown && (
          <PrepCard
            key={shown.event.id}
            prep={shown}
            drafts={drafts}
            tasks={allTasks}
            now={now}
            client={client}
            onClose={picked ? () => selectPrepEvent(null) : undefined}
          />
        )
      )}
    </div>
  );
}
