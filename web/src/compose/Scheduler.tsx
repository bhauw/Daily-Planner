/*
 * Putting something on the calendar, from inside the app.
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
import { ApiError, type CreateEventRequest, type CreateEventResponse } from "../api/client";
import { addMinutesToInput, fromLocalInput, minutesBetweenInputs, toLocalInput } from "./datetime";
import type { SchedulePrefill } from "./types";

type Phase = "edit" | "creating" | "created";

interface SchedulerProps {
  prefill: SchedulePrefill;
  create: (request: CreateEventRequest) => Promise<CreateEventResponse>;
  onClose: () => void;
  onBusyChange?: (busy: boolean) => void;
  onWrote?: () => void;
}

const QUICK_MINUTES = [30, 60, 90, 120];

export function Scheduler({ prefill, create, onClose, onBusyChange, onWrote }: SchedulerProps) {
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
    if (title.trim().length === 0) return "Give it a name.";
    if (!fromLocalInput(start)) return "Check the start time.";
    if (!fromLocalInput(end)) return "Check the end time.";
    if (minutes == null || minutes <= 0) return "The end has to be after the start.";
    return null;
  }, [title, start, end, minutes]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const startISO = fromLocalInput(start);
    const endISO = fromLocalInput(end);
    if (problem || !startISO || !endISO) return;

    setPhase("creating");
    onBusyChange?.(true);
    setError(null);
    try {
      const result = await create({
        title: title.trim(),
        start: startISO,
        end: endISO,
        ...(location.trim() ? { location: location.trim() } : {}),
        ...(notes.trim() ? { description: notes.trim() } : {}),
      });
      setCreated(result);
      setPhase("created");
      onBusyChange?.(false);
      onWrote?.();
    } catch (failure) {
      setPhase("edit");
      onBusyChange?.(false);
      setError(
        failure instanceof ApiError ? failure.message : "That could not be added to your calendar.",
      );
    }
  }

  if (phase === "created" && created) {
    return (
      <div className="compose__done" role="status">
        <div className="compose__donemark" aria-hidden="true">✓</div>
        <h2 className="compose__donetitle">On your calendar</h2>
        <p className="compose__donedetail">{title.trim()}</p>
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
      <h2 className="compose__title">Put it on the day</h2>
      {prefill.context && <p className="compose__context">{prefill.context}</p>}

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

      <label className="compose__field">
        <span className="compose__label">Where <span className="compose__optional">optional</span></span>
        <input className="compose__input" value={location} onChange={(e) => setLocation(e.target.value)} autoComplete="off" />
      </label>

      <label className="compose__field">
        <span className="compose__label">Notes <span className="compose__optional">optional</span></span>
        <textarea className="compose__textarea" value={notes} onChange={(e) => setNotes(e.target.value)} rows={4} />
      </label>

      {error && <p className="compose__error" role="alert">{error}</p>}

      <div className="compose__actions">
        <Button onClick={onClose} disabled={busy}>Cancel</Button>
        <span className="compose__spacer" />
        {problem && <span className="compose__hint">{problem}</span>}
        <Button variant="primary" type="submit" disabled={busy || problem != null}>
          {busy ? "Adding…" : "Add to calendar"}
        </Button>
      </div>
    </form>
  );
}
