/*
 * ThreeColumn — the "Today" surface: Priority · Today · Assistant. Reproduces
 * the approved Option A layout: two equal fluid columns and a fixed-width
 * assistant dock on the right. (The old SwiftUI ThreeColumnLayoutPolicy used
 * equal 0.27 side columns; Option A — the reviewed design — sets Priority and
 * Today equal with a fixed assistant, so we follow Option A and keep a 260px
 * floor on the fluid columns.)
 */

import type { Draft, Preview } from "../api/client";
import { ColumnHeader, EmptyState } from "../components/Column";
import { Dayline } from "../components/Dayline";
import { EventRow } from "../components/EventRow";
import { DraftCard } from "../components/DraftCard";
import { TodayIcon } from "./icons";
import { formatLongDay } from "../lib/format";
import "./three-column.css";

interface ThreeColumnProps {
  preview: Preview;
  drafts: Draft[];
}

function itemCount(n: number): string {
  return `${n} ${n === 1 ? "item" : "items"}`;
}

export function ThreeColumn({ preview, drafts }: ThreeColumnProps) {
  return (
    <div className="threecol">
      <section className="threecol__pane scroll-y" aria-label="Priority queue">
        <ColumnHeader eyebrow="Priority" title="Up next" count={itemCount(preview.queue.length)} />
        <div className="threecol__hairline" />
        {preview.queue.length === 0 ? (
          <EmptyState
            icon={<TodayIcon width={22} height={22} />}
            title="No planning items"
            detail="Choose a planning calendar in Settings, then refresh to see what's next."
          />
        ) : (
          <div role="list">
            {preview.queue.map((event) => (
              <EventRow key={event.id} event={event} />
            ))}
          </div>
        )}
      </section>

      <section className="threecol__pane scroll-y" aria-label="Today's schedule">
        <ColumnHeader
          eyebrow="Today"
          title={formatLongDay(`${preview.day}T09:00:00-07:00`)}
          count={`${preview.schedule.length} ${preview.schedule.length === 1 ? "block" : "blocks"}`}
        />
        <div className="threecol__hairline" />
        {preview.schedule.length === 0 ? (
          <EmptyState
            icon={<TodayIcon width={22} height={22} />}
            title="Your day is clear"
            detail="Planning-calendar items appear here after the next scan."
          />
        ) : (
          <Dayline events={preview.schedule} />
        )}
      </section>

      <aside className="threecol__pane threecol__assistant scroll-y" aria-label="Assistant">
        <ColumnHeader
          eyebrow="Assistant"
          title={drafts.length > 0 ? "Ready" : "Idle"}
          count={`${drafts.length} ${drafts.length === 1 ? "draft" : "drafts"}`}
        />
        <div className="threecol__hairline" />
        <div className="astat">
          <div className="astat__row">
            <span className="astat__ic" aria-hidden="true">✓</span>
            <span>Nothing sent without your approval.</span>
          </div>
          <div className="astat__row">
            <span className="astat__ic" aria-hidden="true">◷</span>
            <span>Next scan 21:00 · Vancouver</span>
          </div>
          {drafts.length === 0 ? (
            <EmptyState
              title="No drafts waiting"
              detail="When the assistant prepares a reply or a calendar bundle, it will wait here for your review."
            />
          ) : (
            drafts.map((draft) => <DraftCard key={draft.id} draft={draft} />)
          )}
        </div>
      </aside>
    </div>
  );
}
