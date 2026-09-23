/*
 * Tasks workspace mount point (task 06). The shell auto-discovers this file via
 * import.meta.glob and mounts it at /tasks (and, detached, at /detach/tasks).
 * See ../README.md for the mounting contract.
 *
 * This root is the orchestrator: it loads the five lists (and, best-effort, the
 * day's schedule for the dayline), owns the proposal reducer and the compose
 * target, and wires the three presentational surfaces — the list columns, the
 * time-blocking dayline, and quick capture. NOTHING here writes: every move,
 * block and capture is a *proposal* resolved in local state only.
 */

import { useReducer, useRef, useState } from "react";
import type { DragEvent } from "react";
import type { PlannerEvent, TaskItem, TaskList, WorkspaceProps } from "../contract";
import { ColumnHeader, ConnectionState, EmptyState, useAsync } from "../contract";
import { BoardScroller } from "./BoardScroller";
import { ListColumns } from "./ListColumns";
import { QuickCapture } from "./QuickCapture";
import { TimeBlockDrag, blockEvents, type ComposeTarget } from "./TimeBlockDrag";
import { firstOpening, gapsFor } from "./insertion";
import { categoryForList, orderLists, routeCapture } from "./routing";
import {
  initialProposalState,
  nextId,
  pendingCount,
  pendingMoveFor,
  proposalReducer,
  type BlockProposal,
  type CaptureProposal,
} from "./machine";
import "./tasks.css";

// The dayline's planning window (matches the shared Dayline default 09:00–21:00).
const WINDOW_START = 9 * 60;
const WINDOW_END = 21 * 60;
// Only when the day has no free gap at all does the keyboard path fall back to a fixed
// opening — and the compose form then names what it overlaps.
const FALLBACK_START = 11 * 60;
const FALLBACK_DURATION = 60;

interface Loaded {
  lists: TaskList[];
  schedule: PlannerEvent[];
  day: string;
}

export default function TasksWorkspace({ api, day, detached }: WorkspaceProps) {
  const { status, data, reload } = useAsync<Loaded>(async () => {
    // The lists are the workspace's reason to exist — they are required.
    const tasksRes = await api.tasks();
    // The schedule is context for time-blocking; if it fails, the dayline
    // degrades to empty and the lists still render.
    let schedule: PlannerEvent[] = [];
    let planningDay = day;
    try {
      const preview = await api.preview();
      schedule = preview.schedule;
      planningDay = preview.day || day;
    } catch {
      // Swallow: no provider content is exposed, and the lists don't need it.
    }
    return { lists: orderLists(tasksRes.lists), schedule, day: planningDay };
  });

  if (status === "disconnected") return <ConnectionState onRetry={reload} />;
  if (status === "loading") {
    return (
      <div className="tasks__loading" role="status" aria-live="polite">
        Loading tasks…
      </div>
    );
  }
  if (status === "error" || !data) {
    return (
      <EmptyState
        title="Couldn't load tasks"
        detail="The engine returned an unexpected response. Try again in a moment."
        action={
          <button type="button" className="btn btn--default btn--sm" onClick={reload}>
            Try again
          </button>
        }
      />
    );
  }

  return <Board data={data} detached={detached} />;
}

function Board({ data, detached }: { data: Loaded; detached: boolean }) {
  const { lists, schedule, day } = data;
  const [state, dispatch] = useReducer(proposalReducer, initialProposalState);
  const [compose, setCompose] = useState<ComposeTarget | null>(null);
  // The task currently being dragged; read on drop to build the block target.
  const dragRef = useRef<{ task: TaskItem; list: string } | null>(null);
  // The control that opened the compose form, so cancelling or proposing hands focus back to
  // it instead of dropping it on <body>.
  const returnFocus = useRef<HTMLElement | null>(null);

  function closeCompose() {
    setCompose(null);
    const el = returnFocus.current;
    returnFocus.current = null;
    if (el && el.isConnected) el.focus();
  }

  const listNames = lists.map((l) => l.name);
  // Planning lists map one-to-one to calendars this round; the compose form
  // offers them as the block's target calendar.
  const calendars = listNames;

  function onDragStartTask(task: TaskItem, fromList: string, e: DragEvent<HTMLDivElement>) {
    dragRef.current = { task, list: fromList };
    e.dataTransfer.effectAllowed = "copy";
    // Identifier only — never any provider content on the drag payload.
    e.dataTransfer.setData("text/plain", task.id);
  }

  function openCompose(task: TaskItem, listName: string, startMin: number, durationMin: number) {
    setCompose({
      taskId: task.id,
      taskTitle: task.title,
      category: task.category,
      listName,
      startMin,
      durationMin,
    });
  }

  // Keyboard-accessible path to a focus block (the WCAG alternative to dragging).
  //
  // It opens on the first free gap — the same gaps a drag drops into, counting blocks already
  // proposed — so pressing the button never defaults onto something that is already there.
  function onBlockTime(task: TaskItem, fromList: string) {
    const live = state.proposals.filter((p): p is BlockProposal => p.kind === "block");
    const gaps = gapsFor([...schedule, ...blockEvents(live)], WINDOW_START, WINDOW_END);
    const at = firstOpening(gaps);
    returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    openCompose(task, fromList, at?.startMin ?? FALLBACK_START, at?.durationMin ?? FALLBACK_DURATION);
  }

  // Drag path: a task was dropped into a gap, which supplied both the start and
  // the length the gap can hold.
  function onDropStart(startMin: number, durationMin: number) {
    const dragged = dragRef.current;
    if (!dragged) return;
    openCompose(dragged.task, dragged.list, startMin, durationMin);
    dragRef.current = null;
  }

  function commitBlock(startMin: number, durationMin: number, calendar: string) {
    if (!compose) return;
    const proposal: BlockProposal = {
      id: nextId("block"),
      status: "pending",
      kind: "block",
      taskId: compose.taskId,
      taskTitle: compose.taskTitle,
      category: compose.category,
      day,
      startMin,
      durationMin,
      calendar,
    };
    dispatch({ type: "add", proposal });
    closeCompose();
  }

  function onProposeMove(task: TaskItem, fromList: string, toList: string) {
    // One pending move per task — approving/rejecting clears the way for another.
    if (pendingMoveFor(state, task.id)) return;
    dispatch({
      type: "add",
      proposal: {
        id: nextId("move"),
        status: "pending",
        kind: "move",
        taskId: task.id,
        taskTitle: task.title,
        category: task.category,
        fromList,
        toList,
      },
    });
  }

  function onCapture(text: string) {
    const routed = routeCapture(text, day, listNames);
    const proposal: CaptureProposal = {
      id: nextId("capture"),
      status: "pending",
      kind: "capture",
      text,
      listName: routed.listName,
      category: routed.category,
      due: routed.due,
      reasons: routed.reasons,
      needsCalendar: routed.needsCalendar,
      needsEmail: routed.needsEmail,
      needsListChoice: routed.needsListChoice,
    };
    dispatch({ type: "add", proposal });
  }

  const resolve = (id: string, next: "approved" | "rejected") =>
    dispatch({ type: "resolve", id, status: next });
  const remove = (id: string) => dispatch({ type: "remove", id });

  const captures = state.proposals.filter((p): p is CaptureProposal => p.kind === "capture");
  const blocks = state.proposals.filter((p): p is BlockProposal => p.kind === "block");
  const pending = pendingCount(state);

  return (
    <div className={["tasks", detached ? "tasks--detached" : ""].filter(Boolean).join(" ")}>
      {/*
       * No page <h1> here either — the outermost heading was ColumnHeader's h3 ("Lists & focus
       * blocks"). sr-only: that title already reads as the page's name on screen.
       */}
      <h1 className="sr-only">Tasks</h1>
      <header className="tasks__bar">
        <ColumnHeader
          eyebrow="Tasks"
          title="Lists & focus blocks"
          count={pending > 0 ? `${pending} proposed` : undefined}
        />
        <QuickCapture
          captures={captures}
          lists={listNames}
          onCapture={onCapture}
          onPickList={(id, listName) =>
            dispatch({ type: "pickList", id, listName, category: categoryForList(listName) })
          }
          onResolve={resolve}
          onDismiss={remove}
        />
      </header>

      <div className="tasks__grid">
        <BoardScroller>
          <ListColumns
            lists={lists}
            day={day}
            state={state}
            onProposeMove={onProposeMove}
            onBlockTime={onBlockTime}
            onResolve={resolve}
            onDragStartTask={onDragStartTask}
          />
        </BoardScroller>

        <aside className="tasks__timeline scroll-y" aria-label="Focus time-blocking">
          <TimeBlockDrag
            schedule={schedule}
            blocks={blocks}
            compose={compose}
            calendars={calendars}
            windowStart={WINDOW_START}
            windowEnd={WINDOW_END}
            onDropStart={onDropStart}
            onCommit={commitBlock}
            onCancel={closeCompose}
            onResolve={resolve}
            onRemove={remove}
          />
        </aside>
      </div>
    </div>
  );
}
