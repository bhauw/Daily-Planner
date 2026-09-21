/*
 * ThreadList — the workbench's left pane: every pending draft in one place.
 *
 * Each row shows the sender/target, subject, a category colour chip, its age,
 * whether a reply is obligated, and the current action status. It is a real
 * listbox: roving tabindex so exactly one row is tab-focusable, arrow keys and
 * j/k move the selection and the focus together, and the selected row is both
 * aria-selected and visibly marked. No clickable <div> — every row is a button.
 */

import { useRef } from "react";
import { Tag, presentationFor } from "../contract";
import { isSendAction } from "./data";
import { statusLabel, type DraftStatus } from "./machine";
import type { Category, Draft } from "../contract";

export interface ThreadRow {
  draft: Draft;
  category: Category;
  status: DraftStatus;
  /** synthetic display age, e.g. "2h". */
  age: string;
  /** whether a reply is obligated (drives the "Reply needed" flag). */
  replyObligated: boolean;
}

interface ThreadListProps {
  rows: ThreadRow[];
  selectedId: string;
  onSelect: (id: string) => void;
}

export function ThreadList({ rows, selectedId, onSelect }: ThreadListProps) {
  const refs = useRef<Record<string, HTMLButtonElement | null>>({});

  function move(delta: number) {
    const i = rows.findIndex((r) => r.draft.id === selectedId);
    if (i < 0) return;
    const next = Math.min(rows.length - 1, Math.max(0, i + delta));
    const id = rows[next].draft.id;
    onSelect(id);
    refs.current[id]?.focus();
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown" || e.key === "j") {
      e.preventDefault();
      move(1);
    } else if (e.key === "ArrowUp" || e.key === "k") {
      e.preventDefault();
      move(-1);
    } else if (e.key === "Home") {
      e.preventDefault();
      const id = rows[0]?.draft.id;
      if (id) {
        onSelect(id);
        refs.current[id]?.focus();
      }
    } else if (e.key === "End") {
      e.preventDefault();
      const id = rows[rows.length - 1]?.draft.id;
      if (id) {
        onSelect(id);
        refs.current[id]?.focus();
      }
    }
  }

  return (
    <div className="mail-threads" role="listbox" aria-label="Pending drafts" aria-orientation="vertical">
      {rows.map((row) => {
        const p = presentationFor({ category: row.category, kind: "event" });
        const selected = row.draft.id === selectedId;
        const send = isSendAction(row.draft.kind);
        return (
          <button
            key={row.draft.id}
            ref={(el) => {
              refs.current[row.draft.id] = el;
            }}
            role="option"
            aria-selected={selected}
            tabIndex={selected ? 0 : -1}
            className={["thread", selected ? "thread--on" : ""].filter(Boolean).join(" ")}
            onClick={() => onSelect(row.draft.id)}
            onKeyDown={onKeyDown}
          >
            <span className="thread__chip" style={{ background: p.colorVar }} aria-hidden="true" />
            <span className="thread__body">
              <span className="thread__topline">
                <span className="thread__subject" title={row.draft.title}>
                  {row.draft.title}
                </span>
                <span className="num thread__age">{row.age}</span>
              </span>
              {row.draft.sender && (
                <span className="thread__sender">{row.draft.sender}</span>
              )}
              <span className="thread__summary">{row.draft.summary}</span>
              <span className="thread__meta">
                <Tag label={p.tag} colorVar={p.colorVar} />
                <span className={["thread__status", `is-${row.status}`].join(" ")}>
                  {statusLabel(row.status)}
                </span>
                {row.replyObligated && send && <span className="thread__flag">Reply needed</span>}
              </span>
            </span>
          </button>
        );
      })}
    </div>
  );
}
