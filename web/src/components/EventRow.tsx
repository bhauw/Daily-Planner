/*
 * EventRow — one PlannerEvent as a list row (Priority queue, Today list, and
 * reused by workspaces). A left colour chip encodes category; the meta row
 * carries the tag and a mono time. The whole row is a single, ignore-children
 * accessibility element with a composed label.
 */

import type { PlannerEvent } from "../api/client";
import { presentationFor } from "../lib/category";
import { formatRange, formatTime } from "../lib/format";
import { Tag } from "./Badge";
import "./event-row.css";

interface EventRowProps {
  event: PlannerEvent;
  /** show start–end instead of just start (Today list uses this). */
  showDuration?: boolean;
  /** optional trailing meta text (e.g. "Reply needed today"). */
  note?: string;
}

export function EventRow({ event, showDuration = false, note }: EventRowProps) {
  const p = presentationFor(event);
  const time = showDuration ? formatRange(event.start, event.end) : formatTime(event.start);
  const label = [p.label, event.title, note, time].filter(Boolean).join(", ");

  return (
    <div className="item" role="listitem" aria-label={label}>
      <span className="item__chip" style={{ background: p.colorVar }} aria-hidden="true" />
      <div className="item__body">
        <div className="item__title" title={event.title}>
          {event.title}
        </div>
        <div className="item__meta" aria-hidden="true">
          <Tag label={p.tag} colorVar={p.colorVar} />
          {note && <span className="item__note">{note}</span>}
          {time && <span className="num item__time">{time}</span>}
        </div>
      </div>
    </div>
  );
}
