/*
 * Focus — what to do next, in priority order.
 *
 * One lead card for the single most urgent thing, then everything else grouped
 * by why it is urgent. The ranking lives in ./priority.ts and every row shows
 * the reason it sits where it does, because an order you cannot explain is an
 * order you cannot trust.
 *
 * Pressing a row opens the actions that fit it — reschedule an event, reply to
 * a message, put a task on the day. The lead card shows its actions without
 * being pressed, because acting on it is the entire point of the surface.
 *
 * Nothing here writes to the account on its own: sending and scheduling open a
 * confirmation step, and every other action is a link or a copy.
 */

import { useMemo } from "react";
import type { Draft, Preview, TasksResponse } from "../api/client";
import { formatRange, formatTime } from "../lib/format";
import { EmptyState } from "../components/Column";
import { focusEvents, groupByRank, rankFocus, type FocusItem, type FocusKind } from "./priority";
import { ActionBar } from "./ActionBar";
import {
  NO_WRITES,
  eventActions,
  replyActions,
  taskActions,
  type ActionCapability,
  type DayContext,
  type ItemAction,
} from "./actions";
import "./focus.css";

const KIND_LABEL: Record<FocusKind, string> = {
  event: "Event",
  task: "Task",
  reply: "Reply",
};

interface FocusProps {
  preview: Preview;
  tasks: TasksResponse;
  drafts: Draft[];
  /** What the connected account may actually do. Drives which actions are live. */
  capability?: ActionCapability;
  /** Injected in tests; the surface reads the real clock in the app. */
  now?: Date;
}

/** The actions that fit whatever this row was built from. */
function actionsFor(item: FocusItem, capability: ActionCapability, day: DayContext): ItemAction[] {
  switch (item.source.kind) {
    case "event":
      // The day's schedule rides along so "Move it" can name what a new time would sit on.
      return eventActions(item.source.event, capability, day.schedule);
    case "task":
      return taskActions(item.source.task, capability, day);
    case "reply":
      return replyActions(item.source.draft, capability);
  }
}

export function Focus({ preview, tasks, drafts, capability = NO_WRITES, now }: FocusProps) {
  // The queue AND the schedule: they are not the same events in two orders, and ranking the
  // schedule alone left every Priority-queue item off the surface meant to say what is next.
  const items = useMemo(
    () => rankFocus({ events: focusEvents(preview), lists: tasks.lists, drafts, now: now ?? new Date() }),
    [preview, tasks.lists, drafts, now],
  );

  const groups = useMemo(() => groupByRank(items), [items]);
  // Today's blocks, so "Put on the day" proposes a gap that is actually free.
  const day = useMemo<DayContext>(() => ({ now, schedule: preview.schedule }), [now, preview.schedule]);

  if (items.length === 0) {
    return (
      <div className="focus">
        <EmptyState
          title="Nothing waiting on you"
          detail="No events, tasks or replies are outstanding. When something needs your attention it appears here, most urgent first."
        />
      </div>
    );
  }

  const [lead, ...rest] = items;
  const restGroups = groups
    .map((group) => ({ ...group, items: group.items.filter((i) => i.id !== lead.id) }))
    .filter((group) => group.items.length > 0);

  return (
    <div className="focus">
      <div className="focus__scroll">
        <LeadCard item={lead} capability={capability} day={day} />

        {rest.length > 0 && (
          <div className="focus__rest">
            {restGroups.map((group) => (
              <section key={group.rank} className="focus__group" aria-label={group.label}>
                <div className="focus__grouphead">
                  <span className="colhead__eyebrow">{group.label}</span>
                  <span className="num focus__groupcount">{group.items.length}</span>
                </div>
                <ul className="focus__list">
                  {group.items.map((item) => (
                    <FocusRow key={`${item.kind}-${item.id}`} item={item} capability={capability} day={day} />
                  ))}
                </ul>
              </section>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

interface RowProps {
  item: FocusItem;
  capability: ActionCapability;
  day: DayContext;
}

function LeadCard({ item, capability, day }: RowProps) {
  const color = item.colorVar;
  const time =
    item.kind === "event" && item.until ? formatRange(item.at ?? "", item.until) : formatTime(item.at);

  return (
    <article
      className="lead"
      // A key scope for its action bar's shortcuts — see ActionBar.
      data-keyscope
      tabIndex={-1}
      aria-label={`Do next: ${item.title}, ${item.reason}`}
      style={{ ["--lead-accent" as string]: color }}
    >
      <div className="lead__eyebrow">Do next</div>
      <h1 className="lead__title">{item.title}</h1>
      <div className="lead__meta">
        <span className="lead__kind" style={{ color }}>
          {KIND_LABEL[item.kind]}
        </span>
        <span className="lead__reason">{item.reason}</span>
        {time && <span className="num lead__time">{time}</span>}
      </div>
      {item.detail && <div className="lead__detail">{item.detail}</div>}
      <ActionBar actions={actionsFor(item, capability, day)} subject={item.title} />
    </article>
  );
}

function FocusRow({ item, capability, day }: RowProps) {
  const color = item.colorVar;
  const time = formatTime(item.at);

  return (
    <li className="focus__rowitem">
      <details className="focus__row" data-keyscope tabIndex={-1}>
        <summary
          className="focus__summary"
          aria-label={`${item.title}, ${item.reason}. Press to show actions.`}
        >
          <span className="item__chip" style={{ background: color }} aria-hidden="true" />
          <span className="item__body">
            <span className="item__title" title={item.title}>
              {item.title}
            </span>
            <span className="item__meta" aria-hidden="true">
              <span className="focus__kind" style={{ color }}>
                {KIND_LABEL[item.kind]}
              </span>
              <span className="item__note">{item.reason}</span>
              {item.detail && <span className="focus__detail">{item.detail}</span>}
            </span>
          </span>
          {time && (
            <span className="num item__time" aria-hidden="true">
              {time}
            </span>
          )}
          <span className="focus__caret" aria-hidden="true">
            <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.6">
              <path d="M6 4l4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
        </summary>
        <div className="focus__actions">
          <ActionBar actions={actionsFor(item, capability, day)} subject={item.title} />
        </div>
      </details>
    </li>
  );
}

export default Focus;
