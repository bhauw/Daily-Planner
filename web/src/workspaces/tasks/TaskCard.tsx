/*
 * TaskCard — one Google Task as a card.
 *
 * Shows the title, the due DATE (never a time-of-day — Google Tasks has no task
 * time), a category chip, and whether a linked calendar focus block exists. The
 * linked block is the product's answer to the date-only limitation, so it is
 * stated plainly on the card when present.
 *
 * A task can be dragged onto the dayline to propose a focus block; because a
 * drag is not keyboard-operable, an equivalent "Block time" button opens the
 * same proposal form (WCAG 2.2 §2.5.7 — a single-pointer/keyboard alternative to
 * dragging). Moving a task to another list is a *proposal*, shown pending until
 * approved; approval is local-only this round.
 */

import type { DragEvent } from "react";
import type { TaskItem } from "../contract";
import { presentationFor, Tag, Button } from "../contract";
import type { BlockProposal, MoveProposal } from "./machine";
import { LOCAL_ONLY_TASKS, statusLabel } from "./machine";
import { describeBlock, linkedBlockFor } from "./data";
import { formatDueDate } from "./routing";
import { ChevronIcon, ClockIcon, GripIcon, LinkIcon } from "./icons";

interface TaskCardProps {
  task: TaskItem;
  day: string;
  lists: string[];
  currentList: string;
  pendingMove: MoveProposal | null;
  /** An approved move that could not be written — shown, so the approval does not vanish. */
  approvedMove?: MoveProposal | null;
  blocks: BlockProposal[];
  onProposeMove: (toList: string) => void;
  onBlockTime: () => void;
  onResolve: (id: string, status: "approved" | "rejected") => void;
  onDragStart: (e: DragEvent<HTMLDivElement>) => void;
}

export function TaskCard({
  task,
  day,
  lists,
  currentList,
  pendingMove,
  approvedMove = null,
  blocks,
  onProposeMove,
  onBlockTime,
  onResolve,
  onDragStart,
}: TaskCardProps) {
  const p = presentationFor({ category: task.category, kind: "event" });
  const dueLabel = formatDueDate(task.due);
  const link = linkedBlockFor(task.id);
  const approvedBlock = blocks.find((b) => b.status === "approved");
  const otherLists = lists.filter((l) => l !== currentList);

  return (
    <div
      className={["task", task.done ? "task--done" : ""].filter(Boolean).join(" ")}
      draggable={!task.done}
      onDragStart={onDragStart}
    >
      <div className="task__grip" aria-hidden="true">
        {!task.done && <GripIcon />}
      </div>

      <div className="task__body">
        <div className="task__top">
          {/*
           * Tag sets its colour inline (style={{ color }}), so the CSS opacity that used to
           * dim .task--done reached it too — and dropped it below 4.5:1. Muted to --text-2
           * here instead: same contrast floor as an active tag's ink, still visibly quieter
           * than the category colour.
           */}
          <Tag label={p.tag} colorVar={task.done ? "var(--text-2)" : p.inkVar} />
          <span className="num task__due">
            {task.done ? "Done" : dueLabel ?? "No due date"}
          </span>
        </div>

        <div className="task__title">{task.title}</div>

        {(link || approvedBlock) && (
          <div className="task__link" title="Linked calendar focus block">
            <LinkIcon />
            <span className="num task__link-text">
              {approvedBlock
                ? describeBlock(
                    { startMin: approvedBlock.startMin, durationMin: approvedBlock.durationMin, calendar: approvedBlock.calendar },
                    approvedBlock.day,
                  )
                : describeBlock(link!, day)}
            </span>
            <span className="task__link-tag">Focus block</span>
          </div>
        )}

        {pendingMove && (
          <div className="task__proposal" role="status">
            <span className="task__proposal-text">
              Proposed move → <strong>{pendingMove.toList}</strong>
            </span>
            <span className="task__proposal-status">{statusLabel(pendingMove.status)}</span>
            <div className="task__proposal-actions">
              <Button size="sm" variant="primary" onClick={() => onResolve(pendingMove.id, "approved")}>
                Approve
              </Button>
              <Button size="sm" variant="ghost" onClick={() => onResolve(pendingMove.id, "rejected")}>
                Reject
              </Button>
            </div>
          </div>
        )}

        {approvedMove && !pendingMove && (
          <div className="task__proposal" role="status">
            <span className="task__proposal-text">
              Move → <strong>{approvedMove.toList}</strong>
            </span>
            <span className="task__proposal-status">{LOCAL_ONLY_TASKS}</span>
          </div>
        )}
      </div>

      {/* Outside the body so the row can use the grip column's width too. */}
      {!task.done && (
        <div className="task__actions">
          {/* Named for its task: eight identical "Block time" buttons told a screen reader
              nothing about which one it was on. */}
          <Button
            size="sm"
            variant="default"
            icon={<ClockIcon />}
            aria-label={`Block time for ${task.title}`}
            onClick={onBlockTime}
          >
            Block time
          </Button>
          {otherLists.length > 0 && (
            <label className="task__move">
              <span className="sr-only">Propose moving “{task.title}” to another list</span>
              <select
                className="task__move-select"
                value=""
                onChange={(e) => {
                  if (e.target.value) onProposeMove(e.target.value);
                  e.target.value = "";
                }}
              >
                <option value="" disabled>
                  Move to…
                </option>
                {otherLists.map((l) => (
                  <option key={l} value={l}>
                    {l}
                  </option>
                ))}
              </select>
              <span className="task__move-caret" aria-hidden="true">
                <ChevronIcon dir="down" size={12} />
              </span>
            </label>
          )}
        </div>
      )}
    </div>
  );
}
