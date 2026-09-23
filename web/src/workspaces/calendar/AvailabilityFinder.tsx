/*
 * AvailabilityFinder — "when can I take a 45-minute coffee chat in the next few days?"
 * Ranked slots that honour every scheduling rule, with the reasoning made visible
 * on every slot (the product's rule: every assumption is stated, never hidden).
 *
 * Rules enforced (all in ./scheduling, the pure engine):
 *  - 9 AM–6 PM weekdays are normal hours; 6–8 PM is a fallback, always LABELLED as
 *    such and only offered when a weekday has no 9–6 opening. Normal-hours slots on
 *    any day rank above every evening fallback ("prefer the next day first").
 *  - Buffers: 15 min virtual / 30 min in-person, plus travel from the prior venue.
 *  - Weekends are skipped.
 *  - FAIL-CLOSED roles: only planning calendars feed availability. This surface is
 *    handed `planning` (already filtered). It also demonstrates the exclusion
 *    explicitly: an opt-in illustration recomputes availability *as if* excluded
 *    calendars counted, so you can see the slots they would have removed — proving
 *    they contribute nothing to the real result.
 */

import { useMemo, useState } from "react";
import type { PlannerEvent } from "../contract";
import { EmptyState } from "../contract";
import { findAvailability, fmtMinutes, type Slot } from "./scheduling";
import { isPlanning, type CalendarState } from "./roles";
import { dayKey, partsOfKey } from "./tz";

interface AvailabilityFinderProps {
  fromKey: string;
  planning: PlannerEvent[];
  allEvents: PlannerEvent[];
  states: CalendarState[];
  /** The clock; injected in tests. Today's slots never start before it. */
  now?: Date;
}

const DURATIONS = [30, 45, 60];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function monthDay(key: string): string {
  const { m, d } = partsOfKey(key);
  return `${MONTHS[m - 1]} ${d}`;
}

export function AvailabilityFinder({ fromKey, planning, allEvents, states, now: nowProp }: AvailabilityFinderProps) {
  const [duration, setDuration] = useState(45);
  const [illustrate, setIllustrate] = useState(false);
  // Read once per mount: a clock that ticked on every render would reshuffle the ranking
  // under the person reading it.
  const [now] = useState(() => nowProp ?? new Date());

  const slots = useMemo(() => findAvailability(planning, fromKey, duration, 7, now).slice(0, 8), [planning, fromKey, duration, now]);

  const excluded = useMemo(() => allEvents.filter((e) => !isPlanning(e, states)), [allEvents, states]);
  const excludedCals = useMemo(() => states.filter((s) => s.role === "excluded"), [states]);

  // The illustration: how many slots WOULD disappear if excluded calendars counted.
  const withExcluded = useMemo(
    () => (illustrate ? findAvailability(allEvents, fromKey, duration, 7, now) : null),
    [illustrate, allEvents, fromKey, duration, now],
  );
  const removedByExcluded = withExcluded ? Math.max(0, findAvailability(planning, fromKey, duration, 7, now).length - withExcluded.length) : 0;
  // It searches seven days starting at the anchor (today by default) — so it says that, not
  // "next week", which is a different set of days.
  const span = fromKey === dayKey(now.toISOString()) ? "the next 7 days" : `the 7 days from ${monthDay(fromKey)}`;

  return (
    <div className="avail">
      <div className="avail__main">
        <div className="avail__controls">
          <span className="avail__label" id="dur-label">
            Find a
          </span>
          <div className="durpick" role="group" aria-labelledby="dur-label">
            {DURATIONS.map((d) => (
              <button key={d} type="button" className="durpick__btn" aria-pressed={duration === d} onClick={() => setDuration(d)}>
                {d} min
              </button>
            ))}
          </div>
          <span className="avail__label">slot in {span} — ranked, normal hours first.</span>
        </div>

        {slots.length === 0 ? (
          <EmptyState
            title={`No open slots in ${span}`}
            detail={`Nothing clears a ${duration}-minute window in normal hours or the evening fallback across ${span}. Try a shorter duration or a later week.`}
          />
        ) : (
          <ol className="slots">
            {slots.map((slot, i) => (
              <SlotRow key={`${slot.dayKey}-${slot.start}`} slot={slot} rank={i + 1} />
            ))}
          </ol>
        )}
      </div>

      <div className="avail__main" aria-label="Excluded calendars">
        <section className="panel">
          <div className="panel__head">Not counted</div>
          {excludedCals.length === 0 ? (
            <p className="roles__note">Every calendar is currently a planning calendar, so all events feed availability.</p>
          ) : (
            <>
              <ul className="legend">
                {excludedCals.map((c) => (
                  <li key={c.id} className="legend__item">
                    <span className="legend__swatch legend__swatch--dashed" style={{ color: "var(--text-3)" }} />
                    {c.title} · excluded
                  </li>
                ))}
              </ul>
              <p className="roles__note">
                {excluded.length} event{excluded.length === 1 ? "" : "s"} on excluded calendars were <strong>not</strong> considered
                above. Excluded calendars are absent from availability by design.
              </p>
            </>
          )}
        </section>

        <section className="panel">
          <div className="panel__head">Prove it</div>
          <label className="excluded-toggle">
            <input type="checkbox" checked={illustrate} onChange={(e) => setIllustrate(e.target.checked)} />
            Show what excluded calendars would block (illustration only)
          </label>
          {illustrate && (
            <p className="roles__note" role="status">
              {excluded.length === 0
                ? "There are no excluded events to compare — nothing would change."
                : removedByExcluded === 0
                  ? "Counting the excluded calendars would not remove any of these slots — but they still never count, by design."
                  : `Counting the excluded calendars would remove ${removedByExcluded} slot${removedByExcluded === 1 ? "" : "s"} from the ranked list. Because they are excluded, those events are ignored and the slots above stand.`}
            </p>
          )}
        </section>
      </div>
    </div>
  );
}

function SlotRow({ slot, rank }: { slot: Slot; rank: number }) {
  return (
    <li className={["slot", slot.fallback ? "slot--fallback" : ""].filter(Boolean).join(" ")}>
      <span className="num slot__rank" aria-hidden="true">
        {rank}
      </span>
      <div className="slot__body">
        <div className="slot__when">
          <span className="slot__day">
            {slot.weekday} {monthDay(slot.dayKey)}
          </span>
          <span className="num slot__time">
            {fmtMinutes(slot.start)}–{fmtMinutes(slot.end)}
          </span>
          <span className="num slot__zone">{slot.zone}</span>
          <span className={["slot__tag", slot.fallback ? "slot__tag--fallback" : ""].filter(Boolean).join(" ")}>
            {slot.fallback ? "After-hours fallback" : "Normal hours"}
          </span>
        </div>
        <ul className="slot__reasons">
          {slot.reasons.map((r, i) => (
            <li key={i} className={["reason", slot.fallback && r.includes("After-hours") ? "reason--fallback" : ""].filter(Boolean).join(" ")}>
              {r}
            </li>
          ))}
        </ul>
      </div>
    </li>
  );
}
