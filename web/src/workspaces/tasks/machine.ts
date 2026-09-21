/*
 * Proposal state — the safety-critical heart of the Tasks workspace.
 *
 * NOTHING in this round writes to Google. Every action a person takes here — move
 * a task between lists, block calendar time for it, capture a new task — produces
 * a *proposal* that waits for their explicit approval, and approval changes only
 * local UI state. There is no write endpoint and this module never calls one.
 *
 * Pure functions and a pure reducer: given a state and an action, return the next
 * state. The UI renders whatever this returns and never mutates a proposal in
 * place. `approved`/`rejected` are local terminal states for this round.
 */

import type { Category } from "../contract";

export type ProposalStatus = "pending" | "approved" | "rejected";

interface Base {
  id: string;
  status: ProposalStatus;
}

/** Propose moving a task from one list to another. Never writes. */
export interface MoveProposal extends Base {
  kind: "move";
  taskId: string;
  taskTitle: string;
  category: Category;
  fromList: string;
  toList: string;
}

/** Propose a linked calendar focus block for a dateless task. Never writes. */
export interface BlockProposal extends Base {
  kind: "block";
  taskId: string;
  taskTitle: string;
  category: Category;
  day: string; // "YYYY-MM-DD"
  startMin: number; // minutes from midnight
  durationMin: number;
  calendar: string;
}

/** Propose a routed new task from quick capture. Never writes. */
export interface CaptureProposal extends Base {
  kind: "capture";
  text: string;
  listName: string;
  category: Category;
  due: string | null; // date only
  reasons: string[];
  needsCalendar: boolean;
  needsEmail: boolean;
}

export type Proposal = MoveProposal | BlockProposal | CaptureProposal;

export interface ProposalState {
  proposals: Proposal[];
}

export type ProposalAction =
  | { type: "add"; proposal: Proposal }
  | { type: "resolve"; id: string; status: "approved" | "rejected" }
  | { type: "remove"; id: string };

export const initialProposalState: ProposalState = { proposals: [] };

export function proposalReducer(state: ProposalState, action: ProposalAction): ProposalState {
  switch (action.type) {
    case "add":
      return { proposals: [action.proposal, ...state.proposals] };
    case "resolve":
      return {
        proposals: state.proposals.map((p) =>
          p.id === action.id ? ({ ...p, status: action.status } as Proposal) : p,
        ),
      };
    case "remove":
      return { proposals: state.proposals.filter((p) => p.id !== action.id) };
  }
}

// ---- id generation ----------------------------------------------------------

let counter = 0;
export function nextId(prefix: string): string {
  counter += 1;
  return `${prefix}-${counter}`;
}

// ---- selectors --------------------------------------------------------------

/** The still-pending move proposal for a task, if any. */
export function pendingMoveFor(state: ProposalState, taskId: string): MoveProposal | null {
  const p = state.proposals.find(
    (x): x is MoveProposal => x.kind === "move" && x.taskId === taskId && x.status === "pending",
  );
  return p ?? null;
}

/** All block proposals for a task (any status), newest first. */
export function blocksFor(state: ProposalState, taskId: string): BlockProposal[] {
  return state.proposals.filter((x): x is BlockProposal => x.kind === "block" && x.taskId === taskId);
}

export function pendingCount(state: ProposalState): number {
  return state.proposals.filter((p) => p.status === "pending").length;
}

const STATUS_LABEL: Record<ProposalStatus, string> = {
  pending: "Needs approval",
  approved: "Approved · local only",
  rejected: "Rejected",
};

export function statusLabel(status: ProposalStatus): string {
  return STATUS_LABEL[status];
}
