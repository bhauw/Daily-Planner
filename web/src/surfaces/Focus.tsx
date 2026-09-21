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
import { groupByRank, rankFocus, type FocusItem, type FocusKind } from "./priority";
import { ActionBar } from "./ActionBar";
import {
  NO_WRITES,
  eventActions,
  replyActions,
  taskActions,
  type ActionCapability,
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
function actionsFor(item: FocusItem, capability: ActionCapability): ItemAction[] {
  switch (item.source.kind) {
    case "event":
      return eventActions(item.source.event, capability);
    case "task":
      return taskActions(item.source.task, capability);
    case "reply":
      return replyActions(item.source.draft, capability);
  }
}

export function Focus({ preview, tasks, drafts, capability = NO_WRITES, now }: FocusProps) {
  // The queue and the schedule are the same events in two orders, so taking the
  // schedule alone avoids ranking everything twice.
  const items = useMemo(
    () => rankFocus({ events: preview.schedule, lists: tasks.lists, drafts, now: now ?? new Date() }),
    [preview.schedule, tasks.lists, drafts, now],
  );

  const groups = useMemo(() => groupByRank(items), [items]);

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
        <LeadCard item={lead} capability={capability} />

        {rest.length > 0 && (
          <div className="focus__rest">
            {restGroups.map((group) => (
              <section key={group.rank} className="focus__group" aria-label={group.label}>
                <div className="focus__grouphead">
                  <span className="colhead__eyebrow">{group.label}</span>
                  <span className="num focus__groupcount">{group.items.length}</span>
                </div>
                <div role="list">
                  {group.items.map((item) => (
                    <FocusRow key={`${item.kind}-${item.id}`} item={item} capability={capability} />
                  ))}
                </div>
              </section>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function LeadCard({ item, capability }: { item: FocusItem; capability: ActionCapability }) {
  const color = item.colorVar;
  const time =
    item.kind === "event" && item.until ? formatRange(item.at ?? "", item.until) : formatTime(item.at);

  return (
    <article
      className="lead"
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
      <ActionBar actions={actionsFor(item, capability)} subject={item.title} />
    </article>
  );
}

function FocusRow({ item, capability }: { item: FocusItem; capability: ActionCapability }) {
  const color = item.colorVar;
  const time = formatTime(item.at);

  return (
    <details className="focus__row" role="listitem">
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
        <ActionBar actions={actionsFor(item, capability)} subject={item.title} />
      </div>
    </details>
  );
}

export default Focus;
