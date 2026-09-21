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

import { useRef, useState } from "react";
import type { DragEvent } from "react";
import type { Category, PlannerEvent } from "../contract";
import { Dayline, Button, EmptyState, formatLongDay, presentationFor } from "../contract";
import type { BlockProposal } from "./machine";
import { statusLabel } from "./machine";
import { isoAt } from "./data";
import { ClockIcon, CheckIcon } from "./icons";

/** The task a compose form is currently proposing a block for. */
export interface ComposeTarget {
  taskId: string;
  taskTitle: string;
  category: Category;
  listName: string;
  startMin: number;
}

interface TimeBlockDragProps {
  schedule: PlannerEvent[];
  blocks: BlockProposal[];
  compose: ComposeTarget | null;
  calendars: string[];
  windowStart: number;
  windowEnd: number;
  /** A task was dropped on the dayline at this start-minute — open compose. */
  onDropStart: (startMin: number) => void;
  onCommit: (startMin: number, durationMin: number, calendar: string) => void;
  onCancel: () => void;
  onResolve: (id: string, status: "approved" | "rejected") => void;
  onRemove: (id: string) => void;
}

const DURATIONS = [30, 45, 60, 90, 120];

/** A proposed/approved block rendered on the dayline as a labelled focus block. */
function blockEvents(blocks: BlockProposal[]): PlannerEvent[] {
  return blocks
    .filter((b) => b.status !== "rejected")
    .map((b) => ({
      id: `blk-${b.id}`,
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
  const [over, setOver] = useState(false);

  const events = [...schedule, ...blockEvents(blocks)];
  const active = blocks.filter((b) => b.status !== "rejected");
  const rejected = blocks.filter((b) => b.status === "rejected");

  function startFromDrop(clientY: number): number {
    const el = wrapRef.current;
    if (!el) return windowStart;
    const rect = el.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clientY - rect.top) / rect.height));
    const raw = windowStart + ratio * (windowEnd - windowStart);
    const snapped = Math.round(raw / 30) * 30;
    return Math.min(windowEnd - 30, Math.max(windowStart, snapped));
  }

  function onDrop(e: DragEvent<HTMLDivElement>) {
    e.preventDefault();
    setOver(false);
    onDropStart(startFromDrop(e.clientY));
  }

  return (
    <div className="timeblock">
      <div className="timeblock__head">
        <div className="timeblock__eyebrow">Focus blocks</div>
        <h3 className="timeblock__title">Block time for a task</h3>
        <p className="timeblock__lede">
          A task keeps only a due date. To give it timed work, place it on the day as a linked focus
          block — drag a card here, or press <kbd className="num">Block time</kbd> on it.
        </p>
      </div>

      {compose && (
        <ComposeForm
          key={`${compose.taskId}-${compose.startMin}`}
          target={compose}
          calendars={calendars}
          windowStart={windowStart}
          windowEnd={windowEnd}
          onCommit={onCommit}
          onCancel={onCancel}
        />
      )}

      <div
        ref={wrapRef}
        className={["timeblock__dayline", over ? "is-over" : ""].filter(Boolean).join(" ")}
        onDragOver={(e) => {
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
          if (!over) setOver(true);
        }}
        onDragLeave={(e) => {
          // Only clear when the pointer truly left the drop zone, not on child enter.
          if (!e.currentTarget.contains(e.relatedTarget as Node)) setOver(false);
        }}
        onDrop={onDrop}
      >
        <Dayline events={events} windowStart={windowStart} windowEnd={windowEnd} />
        {over && (
          <div className="timeblock__dropcue" aria-hidden="true">
            <ClockIcon size={16} />
            <span>Drop to propose a focus block</span>
          </div>
        )}
      </div>

      <section className="timeblock__proposals" aria-label="Proposed focus blocks">
        {active.length === 0 ? (
          <EmptyState
            title="No focus blocks yet"
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
  calendars: string[];
  windowStart: number;
  windowEnd: number;
  onCommit: (startMin: number, durationMin: number, calendar: string) => void;
  onCancel: () => void;
}

function ComposeForm({ target, calendars, windowStart, windowEnd, onCommit, onCancel }: ComposeFormProps) {
  const [startMin, setStartMin] = useState(target.startMin);
  const [durationMin, setDurationMin] = useState(60);
  const [calendar, setCalendar] = useState(
    calendars.includes(target.listName) ? target.listName : calendars[0] ?? target.listName,
  );

  const starts = startOptions(windowStart, windowEnd);
  const endMin = Math.min(windowEnd, startMin + durationMin);
  const p = presentationFor({ category: target.category, kind: "event" });

  return (
    <form
      className="compose"
      style={{ borderLeftColor: p.colorVar }}
      onSubmit={(e) => {
        e.preventDefault();
        onCommit(startMin, durationMin, calendar);
      }}
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
            {DURATIONS.map((d) => (
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
          <Button size="sm" variant="primary" onClick={() => onResolve(block.id, "approved")}>
            Approve
          </Button>
          <Button size="sm" variant="ghost" onClick={() => onResolve(block.id, "rejected")}>
            Reject
          </Button>
          <span className="blockcard__hint">Approving keeps it local — nothing is sent this round.</span>
        </div>
      ) : (
        <p className="blockcard__hint">Local only — the link would be created when writes are enabled.</p>
      )}
    </article>
  );
}

// ---- time helpers (minutes-from-midnight, presentation only) -----------------

function startOptions(windowStart: number, windowEnd: number): number[] {
  const out: number[] = [];
  for (let m = windowStart; m <= windowEnd - 30; m += 30) out.push(m);
  return out;
}

/** "09:30" — a wall-clock label for a minutes-from-midnight value. */
function label(minutes: number): string {
  const h = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0");
  const m = (minutes % 60).toString().padStart(2, "0");
  return `${h}:${m}`;
}
