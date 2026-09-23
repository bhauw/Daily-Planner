/*
 * Putting something on the calendar, from inside the app — or moving something already on it.
 *
 * One step, not two. Creating an event is not like sending mail: the form IS
 * the review — every field that will be written is visible and editable right
 * up to the press — and if it lands wrong it can be changed or deleted. Making
 * this confirm twice would train the habit of clicking through the dialog that
 * actually mattered, which is the one in the composer.
 *
 * Times are wall-clock in the planner's zone and converted on submit. See
 * ./datetime.ts for why that conversion is not `new Date(value)`.
 */

import { useMemo, useState, type FormEvent } from "react";
import { Button } from "../components/Button";
import {
  ApiError,
  type CreateEventRequest,
  type CreateEventResponse,
  type MoveEventRequest,
} from "../api/client";
import { addMinutesToInput, fromLocalInput, minutesBetweenInputs, toLocalInput } from "./datetime";
import type { SchedulePrefill, Written } from "./types";
import { conflictFor } from "../workspaces/calendar/scheduling";

type Phase = "edit" | "creating" | "created";

interface SchedulerProps {
  prefill: SchedulePrefill;
  create: (request: CreateEventRequest) => Promise<CreateEventResponse>;
  /**
   * Moves an event that already exists. Required whenever a prefill can carry `move`; the desk
   * only ever builds such a prefill when the engine reported `canReschedule`.
   */
  move?: (request: MoveEventRequest) => Promise<CreateEventResponse>;
  onClose: () => void;
  onBusyChange?: (busy: boolean) => void;
  onWrote?: (written: Written) => void;
}

const QUICK_MINUTES = [30, 60, 90, 120];

export function Scheduler({ prefill, create, move, onClose, onBusyChange, onWrote }: SchedulerProps) {
  // Moving is only offered when there is something to move it WITH. If a prefill names a target
  // but no mover was wired, the form falls back to creating rather than pressing a button that
  // cannot work — and it says "Add to calendar", so it never claims to move and then duplicate.
  const target = move ? prefill.move : undefined;
  const moving = target != null;
  const [title, setTitle] = useState(prefill.title);
  const [start, setStart] = useState(() => toLocalInput(prefill.start));
  const [end, setEnd] = useState(() => toLocalInput(prefill.end));
  const [location, setLocation] = useState(prefill.location ?? "");
  const [notes, setNotes] = useState(prefill.description ?? "");
  const [phase, setPhase] = useState<Phase>("edit");
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<CreateEventResponse | null>(null);

  const minutes = useMemo(() => minutesBetweenInputs(start, end), [start, end]);
  // Stated rather than merely enforced: the form says why the button is off, instead of leaving
  // the user pressing a dead control and guessing which field it dislikes.
  const problem = useMemo(() => {
    if (!moving && title.trim().length === 0) return "Give it a name.";
    if (!fromLocalInput(start)) return "Check the start time.";
    if (!fromLocalInput(end)) return "Check the end time.";
    if (minutes == null || minutes <= 0) return "The end has to be after the start.";
    return null;
  }, [moving, title, start, end, minutes]);

  // Checked against the day as the times change. It does not disable the button — a student
  // may mean to skip a lecture — but it is said before the press and again after it, so a move
  // onto a class never ends on a clean "Moved".
  const conflict = useMemo(() => {
    const startISO = fromLocalInput(start);
    const endISO = fromLocalInput(end);
    if (!startISO || !endISO || !prefill.busy) return null;
    return conflictFor(prefill.busy, startISO, endISO, target?.eventId);
  }, [start, end, prefill.busy, target?.eventId]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const startISO = fromLocalInput(start);
    const endISO = fromLocalInput(end);
    if (problem || !startISO || !endISO) return;

    setPhase("creating");
    onBusyChange?.(true);
    setError(null);
    try {
      // A move sends the times and nothing else — the same shape the route accepts, so what is
      // on screen is what is written. A create sends the whole draft, as before.
      const result =
        target && move
          ? await move({
              eventId: target.eventId,
              calendarId: target.calendarId,
              start: startISO,
              end: endISO,
            })
          : await create({
              title: title.trim(),
              start: startISO,
              end: endISO,
              ...(location.trim() ? { location: location.trim() } : {}),
              ...(notes.trim() ? { description: notes.trim() } : {}),
            });
      setCreated(result);
      setPhase("created");
      onBusyChange?.(false);
      onWrote?.({ kind: "event" });
    } catch (failure) {
      setPhase("edit");
      onBusyChange?.(false);
      setError(
        failure instanceof ApiError
          ? failure.message
          : moving
          ? "That could not be moved."
          : "That could not be added to your calendar.",
      );
    }
  }

  if (phase === "created" && created) {
    return (
      <div className="compose__done" role="status">
        <div className="compose__donemark" aria-hidden="true">✓</div>
        <h2 className="compose__donetitle">{moving ? "Moved" : "On your calendar"}</h2>
        <p className="compose__donedetail">{title.trim()}</p>
        {conflict && <p className="compose__conflict">⚠ {conflict}</p>}
        <div className="compose__actions">
          {created.htmlLink && (
            <Button onClick={() => window.open(created.htmlLink!, "_blank", "noopener,noreferrer")}>
              Open in Calendar
            </Button>
          )}
          <span className="compose__spacer" />
          <Button variant="primary" onClick={onClose}>Done</Button>
        </div>
      </div>
    );
  }

  const busy = phase === "creating";

  return (
    <form className="compose__form" onSubmit={(e) => void submit(e)}>
      <h2 className="compose__title">{moving ? "Move it" : "Put it on the day"}</h2>
      {prefill.context && <p className="compose__context">{prefill.context}</p>}

      {moving ? (
        // Shown, not editable. This route changes times and nothing else, so an editable name
        // here would quietly discard whatever was typed into it.
        <div className="compose__field">
          <span className="compose__label">What</span>
          <p className="compose__static">{title}</p>
        </div>
      ) : (
        <label className="compose__field">
          <span className="compose__label">What</span>
          <input
            className="compose__input"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
            autoComplete="off"
          />
        </label>
      )}

      <div className="compose__row">
        <label className="compose__field">
          <span className="compose__label">Starts</span>
          <input
            className="compose__input"
            type="datetime-local"
            value={start}
            onChange={(e) => {
              const next = e.target.value;
              // Keep the duration the user already chose when the start moves. Otherwise a
              // nudge to the start silently makes the event longer or inverts it.
              const held = minutes;
              setStart(next);
              if (held != null && held > 0) setEnd(addMinutesToInput(next, held));
            }}
          />
        </label>
        <label className="compose__field">
          <span className="compose__label">Ends</span>
          <input
            className="compose__input"
            type="datetime-local"
            value={end}
            onChange={(e) => setEnd(e.target.value)}
          />
        </label>
      </div>

      <div className="compose__quick" role="group" aria-label="Duration">
        {QUICK_MINUTES.map((n) => (
          <button
            key={n}
            type="button"
            className={`compose__chip${minutes === n ? " compose__chip--on" : ""}`}
            aria-pressed={minutes === n}
            onClick={() => setEnd(addMinutesToInput(start, n))}
          >
            {n < 60 ? `${n} min` : `${n / 60} hr`}
          </button>
        ))}
      </div>

      {/* Absent when moving, for the same reason the name is read-only: the route cannot
          change them, so offering them would be a promise the write does not keep. */}
      {!moving && (
        <>
          <label className="compose__field">
            <span className="compose__label">Where <span className="compose__optional">optional</span></span>
            <input className="compose__input" value={location} onChange={(e) => setLocation(e.target.value)} autoComplete="off" />
          </label>

          <label className="compose__field">
            <span className="compose__label">Notes <span className="compose__optional">optional</span></span>
            <textarea className="compose__textarea" value={notes} onChange={(e) => setNotes(e.target.value)} rows={4} />
          </label>
        </>
      )}

      {conflict && <p className="compose__conflict" role="alert">⚠ {conflict}</p>}
      {error && <p className="compose__error" role="alert">{error}</p>}

      <div className="compose__actions">
        <Button onClick={onClose} disabled={busy}>Cancel</Button>
        <span className="compose__spacer" />
        {problem && <span className="compose__hint">{problem}</span>}
        <Button variant="primary" type="submit" disabled={busy || problem != null}>
          {moving
            ? busy
              ? "Moving…"
              : conflict
              ? "Move anyway"
              : "Move it"
            : busy
            ? "Adding…"
            : conflict
            ? "Add anyway"
            : "Add to calendar"}
        </Button>
      </div>
    </form>
  );
}
