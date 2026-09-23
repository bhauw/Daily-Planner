/*
 * TimeBlockDrag — the time-blocking surface. Google Tasks stores a due DATE and
 * no time; the product's answer is a *linked calendar focus block*, so this is
 * where a dateless task gets timed work proposed for it. It reuses the shared
 * Dayline (never a second timeline) as the day's context, and lets a task be
 * placed on it two ways that produce the identical proposal:
 *
 *   1. Drag a TaskCard onto the dayline — the drop Y maps to a start time.
 *   2. Press "Block time" on the card (keyboard) — opens the same compose form.
 *
 * The keyboard path is not a courtesy: WCAG 2.2 §2.5.7 (Dragging Movements)
 * requires a single-pointer / keyboard alternative to every author-controlled
 * drag, so the drag is pure enhancement over a fully operable form.
 *
 * Nothing here writes. A committed compose adds a *pending* proposal that states
 * its date, start, end, duration and target calendar and waits for approval;
 * approval changes local state only (see machine.ts). The block carries the
 * time — the task never does.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import type { DragEvent } from "react";
import type { Category, PlannerEvent } from "../contract";
import { Dayline, Button, EmptyState, formatLongDay, presentationFor } from "../contract";
import type { BlockProposal } from "./machine";
import { statusLabel } from "./machine";
import { isoAt } from "./data";
import {
  chooseGap,
  describePlacement,
  gapsFor,
  overlapFor,
  placementFor,
  MIN_BLOCK_MIN,
  minutesOfDay,
  type Gap,
  type Placement,
} from "./insertion";
import { ClockIcon, CheckIcon } from "./icons";
// Reached past the contract on purpose, as mail/BookIt does: the write desk is the one path to
// the calendar, and a proposal that can become real must go through it rather than grow its own.
import { useWriteDesk } from "../../compose/WriteDesk";
import { fromLocalInput } from "../../compose/datetime";

/** The task a compose form is currently proposing a block for. */
export interface ComposeTarget {
  taskId: string;
  taskTitle: string;
  category: Category;
  listName: string;
  startMin: number;
  /** The length the drop's gap can hold — the compose form opens on it. */
  durationMin: number;
}

interface TimeBlockDragProps {
  schedule: PlannerEvent[];
  blocks: BlockProposal[];
  compose: ComposeTarget | null;
  calendars: string[];
  windowStart: number;
  windowEnd: number;
  /**
   * A task was dropped into a gap on the dayline — open compose on the time
   * that gap supplies, not on the time under the cursor.
   */
  onDropStart: (startMin: number, durationMin: number) => void;
  onCommit: (startMin: number, durationMin: number, calendar: string) => void;
  onCancel: () => void;
  onResolve: (id: string, status: "approved" | "rejected") => void;
  onRemove: (id: string) => void;
}

const DURATIONS = [30, 45, 60, 90, 120];
// Start times step by a quarter hour — fine enough to say "after dinner, 19:15".
const START_STEP = 15;

/** A proposed/approved block rendered on the dayline as a labelled focus block. */
export function blockEvents(blocks: BlockProposal[]): PlannerEvent[] {
  return blocks
    .filter((b) => b.status !== "rejected")
    .map((b) => ({
      id: `blk-${b.id}`,
      // A proposed focus block is local — it is not on any calendar yet, so there is no id to
      // move it by. An empty string is what `canMove` tests for, so the row offers "add a
      // block" rather than a move that has nothing to patch.
      calendarId: "",
      title: `Focus: ${b.taskTitle}${b.status === "pending" ? " — proposed" : ""}`,
      category: b.category,
      kind: "event" as const,
      start: isoAt(b.day, b.startMin),
      end: isoAt(b.day, b.startMin + b.durationMin),
      due: null,
      location: b.calendar,
    }));
}

export function TimeBlockDrag({
  schedule,
  blocks,
  compose,
  calendars,
  windowStart,
  windowEnd,
  onDropStart,
  onCommit,
  onCancel,
  onResolve,
  onRemove,
}: TimeBlockDragProps) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [insert, setInsert] = useState<{ placement: Placement; top: number } | null>(null);

  const events = [...schedule, ...blockEvents(blocks)];
  const active = blocks.filter((b) => b.status !== "rejected");
  const rejected = blocks.filter((b) => b.status === "rejected");

  // The day's free intervals. Recomputed only when the day changes, not per
  // dragover event — a drag fires these continuously.
  const gapKey = events.map((e) => `${e.id}:${e.start}:${e.end ?? ""}`).join("|");
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const gaps = useMemo(() => gapsFor(events, windowStart, windowEnd), [gapKey, windowStart, windowEnd]);

  /**
   * Where a gap's insertion line is drawn: at the TOP of the block it precedes,
   * or below the last block when it trails the day. Measured off the rendered
   * rows rather than computed from a time, because the dayline is a list of
   * rows of varying height — a proportional position would point at the wrong
   * block. Returns a Y in the wrapper's own coordinates.
   */
  function anchorFor(gap: Gap): number | null {
    const el = wrapRef.current;
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    if (gap.beforeId != null) {
      const row = el.querySelector(`[data-event-id="${CSS.escape(gap.beforeId)}"]`);
      if (row) return (row as HTMLElement).getBoundingClientRect().top - rect.top;
    }
    const rows = el.querySelectorAll("[data-event-id]");
    const last = rows[rows.length - 1] as HTMLElement | undefined;
    if (last) return last.getBoundingClientRect().bottom - rect.top;
    return 0;
  }

  /** The gap the pointer is nearest, resolved to one that can actually hold a block. */
  function placementAt(clientY: number): { placement: Placement; top: number } | null {
    const el = wrapRef.current;
    if (!el || gaps.length === 0) return null;
    const y = clientY - el.getBoundingClientRect().top;

    let nearest = gaps[0];
    let best = Infinity;
    for (const gap of gaps) {
      const anchor = anchorFor(gap);
      if (anchor == null) continue;
      const d = Math.abs(anchor - y);
      if (d < best) {
        best = d;
        nearest = gap;
      }
    }

    // The nearest gap may be too small to take a block; chooseGap walks outward
    // to one that fits, and the line follows it so the cue never promises a
    // slot the drop will not use.
    const gap = chooseGap(gaps, nearest.index, MIN_BLOCK_MIN);
    if (!gap) return null;
    const top = anchorFor(gap);
    return top == null ? null : { placement: placementFor(gap), top };
  }

  function onDrop(e: DragEvent<HTMLDivElement>) {
    e.preventDefault();
    const at = insert ?? placementAt(e.clientY);
    setInsert(null);
    if (!at) return;
    onDropStart(at.placement.startMin, at.placement.durationMin);
  }

  return (
    <div className="timeblock">
      {/*
        * "Block time" names the card's button, not a key, so it is set as a button name rather
        * than as <kbd>. A <kbd> reads as "press this key", and there is no key called that.
        */}
      <div className="timeblock__head">
        <div className="timeblock__eyebrow">Focus blocks</div>
        <h3 className="timeblock__title">Block time for a task</h3>
        <p className="timeblock__lede">
          A task keeps only a due date. To give it timed work, place it on the day as a linked focus
          block — drag a card into a gap between two blocks and it takes that gap's time, or press{" "}
          <strong className="timeblock__btnref">Block time</strong> on it.
        </p>
      </div>

      {compose && (
        <ComposeForm
          key={`${compose.taskId}-${compose.startMin}-${compose.durationMin}`}
          target={compose}
          events={events}
          calendars={calendars}
          windowStart={windowStart}
          windowEnd={windowEnd}
          onCommit={onCommit}
          onCancel={onCancel}
        />
      )}

      <div
        ref={wrapRef}
        className={["timeblock__dayline", insert ? "is-over" : ""].filter(Boolean).join(" ")}
        onDragOver={(e) => {
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
          const at = placementAt(e.clientY);
          setInsert((prev) =>
            prev && at && prev.top === at.top && prev.placement.startMin === at.placement.startMin
              ? prev
              : at,
          );
        }}
        onDragLeave={(e) => {
          // Only clear when the pointer truly left the drop zone, not on child enter.
          if (!e.currentTarget.contains(e.relatedTarget as Node)) setInsert(null);
        }}
        onDrop={onDrop}
      >
        <Dayline events={events} windowStart={windowStart} windowEnd={windowEnd} />
        {insert && (
          <div
            className="timeblock__insert"
            style={{ top: `${insert.top}px` }}
            data-testid="insert-cue"
            aria-hidden="true"
          >
            <span className="timeblock__insert-label num">
              <ClockIcon size={14} />
              {describePlacement(insert.placement)}
            </span>
          </div>
        )}
        <div className="sr-only" role="status" aria-live="polite">
          {insert ? describePlacement(insert.placement) : ""}
        </div>
      </div>

      <section className="timeblock__proposals" aria-label="Proposed focus blocks">
        {active.length === 0 ? (
          // This section lists PROPOSALS, and it sits directly under a timeline that usually
          // already has focus blocks on it — "No focus blocks yet" contradicted the screen.
          <EmptyState
            title="No blocks waiting for approval"
            detail="Block time for a dateless task and the proposal lands here for your approval — nothing is written."
          />
        ) : (
          active.map((b) => (
            <BlockCard key={b.id} block={b} onResolve={onResolve} />
          ))
        )}

        {rejected.length > 0 && (
          <ul className="timeblock__log" aria-label="Rejected focus blocks">
            {rejected.map((b) => (
              <li className="timeblock__log-row" key={b.id}>
                <span className="proposal__status is-rejected">{statusLabel(b.status)}</span>
                <span className="timeblock__log-text">{b.taskTitle}</span>
                <button
                  type="button"
                  className="timeblock__log-dismiss"
                  onClick={() => onRemove(b.id)}
                >
                  <span className="sr-only">Dismiss rejected block for {b.taskTitle}</span>
                  <span aria-hidden="true">×</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

// ---- Compose form: the keyboard-operable path to a block ---------------------

interface ComposeFormProps {
  target: ComposeTarget;
  /** Everything already on the day — the schedule plus live proposals — to check against. */
  events: PlannerEvent[];
  calendars: string[];
  windowStart: number;
  windowEnd: number;
  onCommit: (startMin: number, durationMin: number, calendar: string) => void;
  onCancel: () => void;
}

function ComposeForm({ target, events, calendars, windowStart, windowEnd, onCommit, onCancel }: ComposeFormProps) {
  const [startMin, setStartMin] = useState(target.startMin);
  // The drop's gap decides the opening length; a gap shorter than an hour opens
  // on what it can actually hold rather than on a default that overruns it.
  const [durationMin, setDurationMin] = useState(target.durationMin);
  const [calendar, setCalendar] = useState(
    calendars.includes(target.listName) ? target.listName : calendars[0] ?? target.listName,
  );

  // The drop's own start is rarely on a round step (a lecture ends at 10:20), so it is offered
  // alongside them — a controlled select with no matching option shows its FIRST option, which
  // made the form claim 09:00 while the preview said 10:20.
  const starts = startOptions(windowStart, windowEnd, target.startMin);
  // A gap's length is rarely one of the round numbers, so offer it alongside them.
  const durations = durationOptions(target.durationMin);
  const endMin = Math.min(windowEnd, startMin + durationMin);
  const p = presentationFor({ category: target.category, kind: "event" });
  // Named, not blocked: sometimes a student means to work through a lecture's recording slot.
  // What must not happen is a double-booking proposed without a word.
  const clash = overlapFor(events, startMin, endMin);

  // "Block time" opens this form in the aside, some sixteen tab stops after the card. Focus
  // goes to its first field so the keyboard path does not strand the person on the card.
  const firstField = useRef<HTMLSelectElement>(null);
  useEffect(() => {
    firstField.current?.focus();
  }, []);

  return (
    <form
      className="compose"
      style={{ borderLeftColor: p.colorVar }}
      onSubmit={(e) => {
        e.preventDefault();
        onCommit(startMin, durationMin, calendar);
      }}
      onKeyDown={(e) => {
        // Esc cancels, as any transient form does; the board returns focus to the opener.
        if (e.key === "Escape") {
          e.preventDefault();
          onCancel();
        }
      }}
      aria-label={`Focus block for ${target.taskTitle}`}
    >
      <div className="compose__head">
        <div className="compose__eyebrow">Focus block · needs approval</div>
        <div className="compose__task">{target.taskTitle}</div>
        <p className="compose__note">
          The block carries this time — <strong>{target.taskTitle}</strong> keeps only its due date.
        </p>
      </div>

      <div className="compose__fields">
        <label className="compose__field">
          <span>Starts</span>
          <select
            ref={firstField}
            className="compose__select num"
            value={startMin}
            onChange={(e) => setStartMin(Number(e.target.value))}
          >
            {starts.map((m) => (
              <option key={m} value={m}>
                {label(m)}
              </option>
            ))}
          </select>
        </label>

        <label className="compose__field">
          <span>For</span>
          <select
            className="compose__select num"
            value={durationMin}
            onChange={(e) => setDurationMin(Number(e.target.value))}
          >
            {durations.map((d) => (
              <option key={d} value={d}>
                {d} min
              </option>
            ))}
          </select>
        </label>

        <label className="compose__field">
          <span>Calendar</span>
          <select
            className="compose__select"
            value={calendar}
            onChange={(e) => setCalendar(e.target.value)}
          >
            {calendars.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="compose__preview num" aria-live="polite">
        {label(startMin)}–{label(endMin)} · {durationMin} min · {calendar}
      </div>
      {clash && (
        <p className="compose__warn" role="alert">
          ⚠ Overlaps {clash.title} ({label(minutesOfDay(clash.start) ?? startMin)}–
          {label(minutesOfDay(clash.end) ?? endMin)}). You can still propose it.
        </p>
      )}

      <div className="compose__actions">
        <Button type="submit" size="sm" variant="primary" icon={<CheckIcon />}>
          Propose block
        </Button>
        <Button type="button" size="sm" variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  );
}

// ---- One proposed/approved block, in full ------------------------------------

function BlockCard({ block, onResolve }: { block: BlockProposal; onResolve: (id: string, status: "approved" | "rejected") => void }) {
  const endMin = block.startMin + block.durationMin;
  const dateLabel = formatLongDay(isoAt(block.day, block.startMin));
  const desk = useWriteDesk();
  /*
   * Approving used to change local state and nothing else — it looked like it worked and then
   * nothing was on the calendar, which erodes trust in every other button. With a calendar
   * grant it now opens the scheduler, prefilled with exactly this block; the event exists only
   * once he presses "Add to calendar" there, and the shell's reload then shows it on the day.
   *
   * The instants go through the zone-correct conversion, not `isoAt`: that one hardcodes
   * −07:00, which is fine for a preview and an hour wrong on a real calendar in standard time.
   * No calendar is sent: `block.calendar` is a task-list name, not a calendar id.
   */
  const start = fromLocalInput(`${block.day}T${label(block.startMin)}`);
  const end = fromLocalInput(`${block.day}T${label(endMin)}`);
  const real = desk?.capability.canSchedule === true && start != null && end != null;

  function addToCalendar() {
    desk!.schedule({
      title: `Focus — ${block.taskTitle}`,
      start: start!,
      end: end!,
      context: `Focus block for “${block.taskTitle}”. Nothing is added until you press Add to calendar.`,
    });
  }

  return (
    <article className="blockcard" aria-label={`Focus block for ${block.taskTitle}`}>
      <div className="blockcard__head">
        <div className="blockcard__task">{block.taskTitle}</div>
        <span className={`proposal__status is-${block.status}`}>{statusLabel(block.status)}</span>
      </div>
      <dl className="blockcard__facts">
        <div className="blockcard__fact">
          <dt>Date</dt>
          <dd>{dateLabel}</dd>
        </div>
        <div className="blockcard__fact">
          <dt>Time</dt>
          <dd className="num">
            {label(block.startMin)}–{label(endMin)}
          </dd>
        </div>
        <div className="blockcard__fact">
          <dt>Length</dt>
          <dd className="num">{block.durationMin} min</dd>
        </div>
        <div className="blockcard__fact">
          <dt>Calendar</dt>
          <dd>{block.calendar}</dd>
        </div>
      </dl>
      {block.status === "pending" ? (
        <div className="blockcard__actions">
          {real ? (
            <Button size="sm" variant="primary" onClick={addToCalendar}>
              Add to calendar…
            </Button>
          ) : (
            <Button size="sm" variant="primary" onClick={() => onResolve(block.id, "approved")}>
              Approve
            </Button>
          )}
          <Button size="sm" variant="ghost" onClick={() => onResolve(block.id, "rejected")}>
            Reject
          </Button>
          <span className="blockcard__hint">
            {real
              ? "Opens the event to check — nothing is added until you confirm there."
              : "This account can’t write to Calendar, so approving keeps it local."}
          </span>
        </div>
      ) : (
        <p className="blockcard__hint">Local only — this account can’t write it to Calendar.</p>
      )}
    </article>
  );
}

// ---- time helpers (minutes-from-midnight, presentation only) -----------------

/** The round durations, plus the gap's own length when it is not one of them. */
function durationOptions(gapMin: number): number[] {
  const out = DURATIONS.includes(gapMin) ? [...DURATIONS] : [...DURATIONS, gapMin];
  return out.sort((a, b) => a - b);
}

/** 15-minute steps across the window, plus the opening start when it is not one of them. */
function startOptions(windowStart: number, windowEnd: number, opening: number): number[] {
  const out: number[] = [];
  for (let m = windowStart; m <= windowEnd - MIN_BLOCK_MIN; m += START_STEP) out.push(m);
  if (!out.includes(opening)) out.push(opening);
  return out.sort((a, b) => a - b);
}

/** "09:30" — a wall-clock label for a minutes-from-midnight value. */
function label(minutes: number): string {
  const h = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0");
  const m = (minutes % 60).toString().padStart(2, "0");
  return `${h}:${m}`;
}
