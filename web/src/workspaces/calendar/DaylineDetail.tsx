/*
 * DaylineDetail — the full-height version of the signature dayline for one day.
 * It REUSES the shared <Dayline> (the one and only timeline; it already renders
 * the mono gutter, category blocks, free gaps, transit/duration subtitles, and
 * the workload PressureBar) and surrounds it with the day's controls:
 *
 *  - a category legend (colour is always paired with a label — never colour alone)
 *  - an explicit buffers note (15 min virtual / 30 min in-person + travel)
 *  - the calendars/roles list (fail-closed: toggling re-scopes what counts; it is
 *    LOCAL view state only and writes nothing)
 *  - reschedule: a flexible block can be proposed to a new time by keyboard
 *    (−/+ 15 min) or drag (in the Week grid). A proposal shows a before → after
 *    diff, an explicit "needs approval" state, and any collision — and is never
 *    sent anywhere this round. Approving changes local state only.
 */

import { useMemo } from "react";
import type { PlannerEvent } from "../contract";
import { presentationFor, colorForCategory, Dayline, Button } from "../contract";
import { isFlexible, fixedReason, eventInterval, intervalOnDay, fmtMinutes } from "./scheduling";
import { categoryForTitle, type CalendarState } from "./roles";
import { whenLabel, type Proposal } from "./proposals";
import { WINDOW_START, WINDOW_END } from "./layout";

interface DaylineDetailProps {
  dayKey: string;
  events: PlannerEvent[];
  planning: PlannerEvent[];
  states: CalendarState[];
  roleOf: (e: PlannerEvent) => "planning" | "excluded";
  showExcluded: boolean;
  proposals: Map<string, Proposal>;
  /** Proposals accepted locally; the events handed in already sit at the accepted time. */
  accepted: Map<string, Proposal>;
  onPropose: (event: PlannerEvent, dayKey: string, toStart: number) => void;
  onApprove: (id: string) => void;
  onDiscard: (id: string) => void;
  onToggleRole: (id: string) => void;
  onExplainFixed: (event: PlannerEvent) => void;
}

function clampStart(toStart: number, duration: number): number {
  return Math.max(WINDOW_START, Math.min(WINDOW_END - duration, toStart));
}

export function DaylineDetail({
  dayKey,
  events,
  planning,
  states,
  roleOf,
  showExcluded,
  proposals,
  accepted,
  onPropose,
  onApprove,
  onDiscard,
  onToggleRole,
  onExplainFixed,
}: DaylineDetailProps) {
  // Every event on the day, including one that started the day before and runs into it.
  const planningDay = useMemo(() => planning.filter((e) => intervalOnDay(e, dayKey) != null), [planning, dayKey]);
  const excludedDay = useMemo(
    () => events.filter((e) => intervalOnDay(e, dayKey) != null && roleOf(e) === "excluded"),
    [events, dayKey, roleOf],
  );
  const flexibleDay = useMemo(() => planningDay.filter(isFlexible), [planningDay]);
  const fixedDay = useMemo(() => planningDay.filter((e) => !isFlexible(e)), [planningDay]);

  const legend = useMemo(() => {
    const seen = new Map<string, string>();
    for (const e of planningDay) {
      const p = presentationFor(e);
      if (!seen.has(p.colorVar)) seen.set(p.colorVar, p.label);
    }
    return [...seen.entries()].map(([colorVar, label]) => ({ colorVar, label }));
  }, [planningDay]);

  function currentStart(e: PlannerEvent): number {
    const iv = eventInterval(e);
    return proposals.get(e.id)?.toStart ?? (iv ? iv.start : WINDOW_START);
  }

  function move(e: PlannerEvent, delta: number) {
    const iv = eventInterval(e);
    if (!iv) return;
    const duration = iv.end - iv.start;
    // Nudge on the day the proposal is already going to. Passing this view's day silently
    // dragged a cross-day proposal back onto the source day.
    const target = proposals.get(e.id)?.dayKey ?? dayKey;
    onPropose(e, target, clampStart(currentStart(e) + delta, duration));
  }

  return (
    <div className="dayview">
      <div>
        {planningDay.length === 0 ? (
          <div className="panel">
            <div className="panel__head">Nothing scheduled</div>
            <p className="buffernote">This day has no planning events. Excluded reference calendars are never shown here unless you turn them on in the toolbar.</p>
          </div>
        ) : (
          <Dayline events={planningDay} windowStart={WINDOW_START} windowEnd={WINDOW_END} />
        )}

        {showExcluded && excludedDay.length > 0 && (
          <div className="panel" style={{ marginTop: "var(--space-8)" }}>
            <div className="panel__head">Excluded reference — not counted</div>
            <ul className="legend">
              {excludedDay.map((e) => (
                <li key={e.id} className="legend__item">
                  <span className="legend__swatch legend__swatch--dashed" style={{ color: "var(--text-3)" }} />
                  {e.title} · {presentationFor(e).label} · shown for context only
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      <div className="dayview__side">
        <section className="panel" aria-label="Legend">
          <div className="panel__head">Legend</div>
          <ul className="legend">
            {legend.length === 0 && <li className="legend__item">No categories scheduled today.</li>}
            {legend.map((l) => (
              <li key={l.colorVar} className="legend__item">
                <span className="legend__swatch" style={{ color: l.colorVar }} />
                {l.label}
              </li>
            ))}
          </ul>
        </section>

        <section className="panel" aria-label="Buffers and travel">
          <div className="panel__head">Buffers &amp; travel</div>
          <p className="buffernote">
            Availability keeps <strong>15 min</strong> around virtual meetings and <strong>30 min</strong> around in-person
            ones, plus travel time from the prior location. In-person blocks show their location so the transit assumption is
            visible.
          </p>
        </section>

        <section className="panel" aria-label="Calendars">
          <div className="panel__head">Calendars</div>
          <div className="roles">
            {states.map((s) => {
              const cat = categoryForTitle(s.title);
              const swatch = cat ? colorForCategory(cat) : "var(--text-3)";
              const excluded = s.role === "excluded";
              return (
                <div key={s.id} className={["role", excluded ? "role--excluded" : ""].filter(Boolean).join(" ")}>
                  <span className="role__name">
                    <span className="role__swatch" style={{ background: swatch }} aria-hidden="true" />
                    <span className="role__title">{s.title}</span>
                  </span>
                  <span className="role__meta">
                    <span className={`role__state role__state--${s.role}`}>{s.role}</span>
                    <Button
                      variant="default"
                      size="sm"
                      onClick={() => onToggleRole(s.id)}
                      aria-label={`${excluded ? "Include" : "Exclude"} ${s.title} — ${excluded ? "count it toward availability" : "stop counting it"}`}
                    >
                      {excluded ? "Include" : "Exclude"}
                    </Button>
                  </span>
                </div>
              );
            })}
          </div>
          <p className="roles__note">
            Fail-closed: only <strong>planning</strong> calendars affect availability, workload, and conflicts. A new or
            unknown calendar defaults to excluded. Toggling is local view state — it never writes to Google.
          </p>
        </section>

        <section className="panel reschedule" aria-label="Reschedule">
          <div className="panel__head">Reschedule (proposals only)</div>
          {flexibleDay.length === 0 && <p className="fixedhint">No flexible blocks today. Only focus/deadline work blocks can be proposed to a new time.</p>}

          {flexibleDay.map((e) => {
            const iv = eventInterval(e);
            const duration = iv ? iv.end - iv.start : 45;
            const proposal = proposals.get(e.id);
            const isAccepted = accepted.has(e.id);
            const cur = currentStart(e);
            return (
              <div className="movable" key={e.id}>
                <div className="movable__row">
                  <span className="movable__name">{e.title}</span>
                  <span className="num movable__time">{fmtMinutes(cur)}</span>
                </div>
                <div className="movable__controls">
                  <button type="button" className="stepbtn" aria-label={`Move ${e.title} 15 minutes earlier`} onClick={() => move(e, -15)}>
                    −15
                  </button>
                  <button type="button" className="stepbtn" aria-label={`Move ${e.title} 15 minutes later`} onClick={() => move(e, 15)}>
                    +15
                  </button>
                  <span className="fixedhint">{duration} min block</span>
                </div>

                {proposal && (
                  <div className="proposal" role="group" aria-label={`Proposed change for ${e.title}`}>
                    <span className="proposal__flag">● Proposal · needs approval</span>
                    <div className="proposal__diff">
                      <div className="diffcol">
                        <span className="diffcol__label">Now</span>
                        <span className="num diffcol__time">{whenLabel(proposal.fromDayKey, proposal.fromStart)}</span>
                      </div>
                      <span className="diff__arrow" aria-hidden="true">
                        →
                      </span>
                      <div className="diffcol">
                        <span className="diffcol__label">Proposed</span>
                        <span className="num diffcol__time">{whenLabel(proposal.dayKey, proposal.toStart)}</span>
                      </div>
                    </div>
                    {proposal.collision && <p className="proposal__warn">⚠ {proposal.collision}</p>}
                    <p className="proposal__note">Nothing is sent this round — approving records it locally only.</p>
                    <div className="proposal__actions">
                      <Button variant="primary" size="sm" onClick={() => onApprove(e.id)}>
                        Approve locally
                      </Button>
                      <Button variant="ghost" size="sm" onClick={() => onDiscard(e.id)}>
                        Discard
                      </Button>
                    </div>
                  </div>
                )}

                {isAccepted && !proposal && (
                  <p className="proposal__note" role="status">
                    Accepted locally at {fmtMinutes(cur)} · nothing was sent.
                  </p>
                )}
              </div>
            );
          })}

          {fixedDay.length > 0 && (
            <div className="reschedule">
              <p className="fixedhint">Fixed today (can't be moved):</p>
              {fixedDay.map((e) => (
                <button
                  key={e.id}
                  type="button"
                  className="movable__row"
                  style={{ background: "transparent", border: "none", padding: 0, cursor: "pointer", width: "100%" }}
                  onClick={() => onExplainFixed(e)}
                  aria-label={`${e.title} — why it can't move`}
                >
                  <span className="movable__name">{e.title}</span>
                  <span className="fixedhint">{fixedReason(e)}</span>
                </button>
              ))}
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
