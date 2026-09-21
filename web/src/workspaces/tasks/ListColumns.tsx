/*
 * ListColumns — the five task lists side by side (School · Career · Finance ·
 * Personal · General), each with its own count and its own independent scroll so
 * a list with far more items than the others never forces the row to grow or the
 * layout to collapse. Colour comes only from the shared category tokens.
 */

import type { DragEvent } from "react";
import type { TaskItem, TaskList } from "../contract";
import { ColumnHeader, EmptyState } from "../contract";
import { TaskCard } from "./TaskCard";
import type { ProposalState } from "./machine";
import { blocksFor, pendingMoveFor } from "./machine";
import { listColorVar } from "./routing";

interface ListColumnsProps {
  lists: TaskList[];
  day: string;
  state: ProposalState;
  onProposeMove: (task: TaskItem, fromList: string, toList: string) => void;
  onBlockTime: (task: TaskItem, fromList: string) => void;
  onResolve: (id: string, status: "approved" | "rejected") => void;
  onDragStartTask: (task: TaskItem, fromList: string, e: DragEvent<HTMLDivElement>) => void;
}

export function ListColumns({
  lists,
  day,
  state,
  onProposeMove,
  onBlockTime,
  onResolve,
  onDragStartTask,
}: ListColumnsProps) {
  const listNames = lists.map((l) => l.name);

  return (
    <div className="tasklists" role="list" aria-label="Task lists">
      {lists.map((list) => {
        const open = list.items.filter((i) => !i.done).length;
        return (
          <section
            className="tasklist"
            role="listitem"
            key={list.name}
            aria-label={`${list.name}, ${open} open`}
          >
            <div className="tasklist__accent" style={{ background: listColorVar(list.name) }} />
            <ColumnHeader eyebrow="List" title={list.name} count={String(open)} />
            <div className="tasklist__body scroll-y">
              {list.items.length === 0 ? (
                <EmptyState
                  title="Nothing here yet"
                  detail={`Capture a task and it can route to ${list.name}.`}
                />
              ) : (
                list.items.map((task) => (
                  <TaskCard
                    key={task.id}
                    task={task}
                    day={day}
                    lists={listNames}
                    currentList={list.name}
                    pendingMove={pendingMoveFor(state, task.id)}
                    blocks={blocksFor(state, task.id)}
                    onProposeMove={(toList) => onProposeMove(task, list.name, toList)}
                    onBlockTime={() => onBlockTime(task, list.name)}
                    onResolve={onResolve}
                    onDragStart={(e) => onDragStartTask(task, list.name, e)}
                  />
                ))
              )}
            </div>
          </section>
        );
      })}
    </div>
  );
}
