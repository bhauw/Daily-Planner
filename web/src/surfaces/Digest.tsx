/*
 * Digest — the inbox, ordered by what a message is ABOUT, with the day's load
 * around it.
 *
 * It used to be a second Focus: the same rows, the same stylesheet, the
 * schedule first and mail as one undifferentiated "needs a reply" pile. Mail
 * leads now, because that is the thing that arrives whether you look or not.
 *
 * Read first holds the four overrides — a security warning, an interview, a
 * stated deadline, a payment — and each row says the phrase that put it there.
 * Under it, mail sits in Braxton's order: school, recruiting, finance,
 * personal, other. The schedule and what is due follow as WORKLOAD: the
 * context that decides whether a reply can wait.
 *
 * The ranking is the engine's (`MailTriagePolicy`). This file groups it and
 * never re-sorts it — a rank each surface re-derives is one that eventually
 * disagrees with itself.
 *
 * Rows are <details>/<summary>: keyboard and screen-reader behaviour comes
 * from the platform rather than from a pile of ARIA we would have to maintain.
 *
 * Read-only: nothing here sends, schedules, completes or edits anything.
 */

import { useMemo } from "react";
import type { Draft, PlannerEvent, Preview, TaskItem, TasksResponse, WeekResponse } from "../api/client";
import { colorForCategory, presentationFor } from "../lib/category";
import { durationMinutes, formatLongDay, formatRange, formatTime } from "../lib/format";
import { EmptyState } from "../components/Column";
import { relative } from "./priority";
import { REASON_LABEL, groupMail, waitingOn } from "./mailTriage";
import { ActionBar } from "./ActionBar";
import { NO_WRITES, eventActions, replyActions, taskActions, type ActionCapability } from "./actions";
import "./digest.css";

interface DigestProps {
  preview: Preview;
  tasks: TasksResponse;
  drafts: Draft[];
  /** Promotions and spam the engine withheld, so the surface can say so. */
  hiddenCount?: number;
  /** The next seven days. Null when the engine could not be asked — the section then says so. */
  week?: WeekResponse | null;
  /** What the connected account may actually do. Drives which actions are live. */
  capability?: ActionCapability;
  /** Injected in tests; the surface reads the real clock in the app. */
  now?: Date;
}

const ZONE = "America/Vancouver";

const DAY_KEY = new Intl.DateTimeFormat("en-CA", {
  timeZone: ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

const WEEKDAY = new Intl.DateTimeFormat("en-CA", {
  timeZone: ZONE,
  weekday: "short",
  month: "short",
  day: "numeric",
});

function dayKey(iso: string | null): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : DAY_KEY.format(d);
}

interface OpenTask {
  task: TaskItem;
  list: string;
}

export function Digest({
  preview,
  tasks,
  drafts,
  hiddenCount = 0,
  week,
  capability = NO_WRITES,
  now,
}: DigestProps) {
  const clock = now ?? new Date();
  const nowMs = clock.getTime();
  const todayKey = DAY_KEY.format(clock);

  const openTasks = useMemo<OpenTask[]>(
    () =>
      tasks.lists.flatMap((list) =>
        list.items.filter((t) => !t.done).map((task) => ({ task, list: list.name })),
      ),
    [tasks.lists],
  );

  // "Due" means due today or already late. A task due next week is not part of
  // today's brief — it belongs to the week section.
  const dueTasks = useMemo(
    () =>
      openTasks
        .filter(({ task }) => {
          const key = dayKey(task.due);
          if (!key) return false;
          return key <= todayKey;
        })
        .sort((a, b) => (a.task.due ?? "").localeCompare(b.task.due ?? "")),
    [openTasks, todayKey],
  );

  // Grouped, never re-sorted: the list arrives ranked.
  const mail = useMemo(() => groupMail(drafts), [drafts]);
  const replies = useMemo(() => drafts.filter((d) => d.kind === "reply"), [drafts]);

  const schedule = useMemo(
    () => [...preview.schedule].sort((a, b) => a.start.localeCompare(b.start)),
    [preview.schedule],
  );

  // The days after today, grouped. `/api/week` covers today too, so today is
  // filtered out here rather than served twice. Falls back to the preview when
  // the week could not be read, which yields an empty list and an honest note.
  const weekAhead = useMemo(() => {
    const source = week?.events ?? preview.schedule;
    const later = source.filter((e) => {
      const key = dayKey(e.start);
      return key !== null && key > todayKey;
    });
    const byDay = new Map<string, PlannerEvent[]>();
    for (const event of later) {
      const key = dayKey(event.start)!;
      byDay.set(key, [...(byDay.get(key) ?? []), event]);
    }
    return [...byDay.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, events]) => ({
        key,
        label: WEEKDAY.format(new Date(events[0].start)),
        events: events.sort((a, b) => a.start.localeCompare(b.start)),
      }));
  }, [week, preview.schedule, todayKey]);

  // The workload line. Mail first, because that is what the surface now leads with.
  const summary = [
    // "unread" is its own plural — the default "s" made it "4 unreads".
    mail.unreadCount > 0 ? count(mail.unreadCount, "unread", "unread") : count(replies.length, "message"),
    mail.urgent.length > 0 ? `${mail.urgent.length} to read first` : "",
    count(schedule.length, "event"),
    count(dueTasks.length, "task due"),
  ]
    .filter(Boolean)
    .join(" · ");

  const nothingToday = schedule.length === 0 && replies.length === 0 && dueTasks.length === 0;

  const weekCount = weekAhead.reduce((n, d) => n + d.events.length, 0);
  const noMail = mail.urgent.length === 0 && mail.groups.length === 0;

  /*
   * One scroller with a pinned header.
   *
   * Reading down the inbox used to push the date and summary off the top, so the header is
   * sticky. The inbox and the day's load were once two nested scroll panes, the load capped at
   * 40%; that cap sliced the last visible reply in half at every window size, so they are now
   * consecutive bands of one reading column (see digest.css).
   */
  return (
    <div className="digest">
      <header className="digest__head">
        <div className="colhead__eyebrow">Digest</div>
        <h1 className="digest__title">{formatLongDay(preview.schedule[0]?.start ?? clock.toISOString())}</h1>
        <p className="digest__summary">{summary || "Nothing scheduled, nothing waiting."}</p>
      </header>

      <div className="digest__mail">
        {nothingToday ? (
          <EmptyState
            title="Your day is clear"
            detail="No events, no replies waiting, nothing due. Today's load is below."
          />
        ) : noMail ? (
          <EmptyState title="Inbox is clear" detail="Nothing waiting on a reply." />
        ) : (
          <>
            {mail.urgent.length > 0 && (
              <Section title="Read first" count={mail.urgent.length}>
                {mail.urgent.map((draft) => (
                  <ReplyDetail key={draft.id} draft={draft} nowMs={nowMs} capability={capability} />
                ))}
              </Section>
            )}

            {mail.groups.map((group) => (
              <Section key={group.key} title={group.title} count={group.drafts.length}>
                {group.drafts.map((draft) => (
                  <ReplyDetail key={draft.id} draft={draft} nowMs={nowMs} capability={capability} />
                ))}
              </Section>
            ))}

            {hiddenCount > 0 && (
              <p className="digest__note">
                {count(hiddenCount, "promotion")} hidden. Hiding them is only honest if it says
                so.
              </p>
            )}
          </>
        )}
      </div>

      <div className="digest__load" aria-label="Today's load">
        {schedule.length > 0 && (
          <Section title="Today" count={schedule.length}>
            {schedule.map((event) => (
              <EventDetail key={event.id} event={event} nowMs={nowMs} capability={capability} around={week?.events ?? preview.schedule} />
            ))}
          </Section>
        )}

        {dueTasks.length > 0 && (
          <Section title="Due" count={dueTasks.length}>
            {dueTasks.map(({ task, list }) => (
              <TaskDetail
                key={task.id}
                task={task}
                list={list}
                nowMs={nowMs}
                todayKey={todayKey}
                capability={capability}
                clock={clock}
                schedule={preview.schedule}
              />
            ))}
          </Section>
        )}

        <Section title="The week ahead" count={weekCount}>
          {weekAhead.length === 0 ? (
            <p className="digest__note">
              {week
                ? "Nothing scheduled for the next seven days."
                : "The week ahead could not be loaded. Today above is unaffected."}
            </p>
          ) : (
            weekAhead.map((day) => (
              <div key={day.key} className="digest__day">
                <div className="digest__daylabel">{day.label}</div>
                {day.events.map((event) => (
                  <EventDetail key={event.id} event={event} nowMs={nowMs} capability={capability} around={week?.events ?? preview.schedule} />
                ))}
              </div>
            ))
          )}
        </Section>
      </div>
    </div>
  );
}

function count(n: number, one: string, many?: string): string {
  if (n === 0) return "";
  return `${n} ${n === 1 ? one : (many ?? `${one}s`)}`;
}

function Section({ title, count: n, children }: { title: string; count: number; children: React.ReactNode }) {
  return (
    <section className="digest__section" aria-label={title}>
      <div className="digest__sectionhead">
        <span className="colhead__eyebrow">{title}</span>
        {n > 0 && <span className="num digest__sectioncount">{n}</span>}
      </div>
      {children}
    </section>
  );
}

/** One expandable row. `summary` is always visible; `children` opens beneath it. */
function Row({
  color,
  title,
  meta,
  trailing,
  label,
  badge,
  children,
}: {
  color: string;
  title: string;
  meta: string;
  trailing?: string;
  label: string;
  /** Shown only on rows that jumped the category order, so the jump is visible. */
  badge?: string;
  children: React.ReactNode;
}) {
  return (
    // A key scope: once open, its action bar's keys act on this row and no other.
    <details className="drow" data-keyscope tabIndex={-1}>
      <summary className="drow__summary" aria-label={label}>
        <span className="drow__chip" style={{ background: color }} aria-hidden="true" />
        <span className="drow__body">
          <span className="drow__title">
            {badge && <span className="drow__badge">{badge}</span>}
            {title}
          </span>
          <span className="drow__meta">{meta}</span>
        </span>
        {trailing && <span className="num drow__trailing">{trailing}</span>}
        <span className="drow__caret" aria-hidden="true">
          <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.6">
            <path d="M6 4l4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
      </summary>
      <div className="drow__detail">{children}</div>
    </details>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="dfield">
      <span className="dfield__label">{label}</span>
      <span className="dfield__value">{value}</span>
    </div>
  );
}

function EventDetail({
  event,
  nowMs,
  capability,
  around,
}: {
  event: PlannerEvent;
  nowMs: number;
  capability: ActionCapability;
  /** Everything on the calendar, so "Move it" can name what a new time overlaps. */
  around: PlannerEvent[];
}) {
  const p = presentationFor(event);
  const range = formatRange(event.start, event.end);
  const mins = durationMinutes(event.start, event.end);
  const startMs = new Date(event.start).getTime();

  return (
    <Row
      color={p.colorVar}
      title={event.title}
      meta={p.label}
      trailing={range}
      label={`${event.title}, ${p.label}, ${range}`}
    >
      <Field label="When" value={range || formatTime(event.start)} />
      {mins !== null && <Field label="Duration" value={`${mins} min`} />}
      {!Number.isNaN(startMs) && <Field label="Starts" value={relative(nowMs, startMs)} />}
      {event.location && <Field label="Where" value={event.location} />}
      <Field label="Category" value={p.label} />
      {event.due && <Field label="Due" value={formatTime(event.due)} />}
      <ActionBar actions={eventActions(event, capability, around)} subject={event.title} />
    </Row>
  );
}

function ReplyDetail({
  draft,
  nowMs,
  capability,
}: {
  draft: Draft;
  nowMs: number;
  capability: ActionCapability;
}) {
  const color = colorForCategory(draft.category ?? "other");
  const received = draft.receivedAt ? new Date(draft.receivedAt).getTime() : NaN;
  const age = Number.isNaN(received) ? "" : relative(nowMs, received);
  // Only the overrides get a badge. Putting one on every row would make the four that
  // actually jumped the queue indistinguishable from the rest.
  const badge = draft.band === "urgent" && draft.reason ? REASON_LABEL[draft.reason] : undefined;
  // Derived, not hardcoded: a statement or a no-reply alert is not waiting on a reply.
  const waiting = waitingOn(draft);

  return (
    <Row
      color={color}
      title={draft.title}
      meta={draft.sender ?? "Unknown sender"}
      trailing={draft.receivedAt ? formatTime(draft.receivedAt) : undefined}
      label={`${draft.title}, from ${draft.sender ?? "unknown sender"}${
        badge ? `, ${badge}` : ""
      }`}
      badge={badge}
    >
      {draft.why && <Field label="Why it is here" value={draft.why} />}
      {draft.sender && <Field label="From" value={draft.sender} />}
      {age && <Field label="Arrived" value={age} />}
      {draft.summary && <Field label="What it says" value={draft.summary} />}
      {waiting && <Field label="Waiting on" value={waiting} />}
      <ActionBar actions={replyActions(draft, capability)} subject={draft.title} />
    </Row>
  );
}

function TaskDetail({
  task,
  list,
  nowMs,
  todayKey,
  capability,
  clock,
  schedule,
}: {
  task: TaskItem;
  list: string;
  nowMs: number;
  todayKey: string;
  capability: ActionCapability;
  clock: Date;
  /** Today's blocks, so the proposed slot is a free one before the due. */
  schedule: PlannerEvent[];
}) {
  const color = colorForCategory(task.category);
  const key = dayKey(task.due);
  const late = key !== null && key < todayKey;
  const dueMs = task.due ? new Date(task.due).getTime() : NaN;

  return (
    <Row
      color={color}
      title={task.title}
      meta={late ? "Overdue" : "Due today"}
      trailing={list}
      label={`${task.title}, ${late ? "overdue" : "due today"}, list ${list}`}
    >
      <Field label="List" value={list} />
      <Field label="Status" value={late ? "Overdue" : "Due today"} />
      {!Number.isNaN(dueMs) && <Field label="Deadline" value={relative(nowMs, dueMs)} />}
      <ActionBar actions={taskActions(task, capability, { now: clock, schedule })} subject={task.title} />
    </Row>
  );
}

export default Digest;
