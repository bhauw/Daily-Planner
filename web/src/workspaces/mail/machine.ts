/*
 * The draft action state machine — binding, from the product spec:
 *
 *   proposed → edited → preflighted → approved
 *   Any payload change after approval returns the action to `edited` and
 *   INVALIDATES the approval. There is no direct proposed→approved or
 *   edited→approved transition — approval always passes through preflight.
 *
 * This is the safety-critical heart of the workbench, so it lives as pure
 * functions with no React and no I/O: given a state and an event, return the
 * next state. The UI renders whatever this returns; it never sets a status
 * directly. `rejected` is a local terminal state for this round (nothing sends).
 */

export type DraftStatus = "proposed" | "edited" | "preflighted" | "approved" | "rejected";

export interface DraftState {
  status: DraftStatus;
  subject: string;
  body: string;
  /**
   * True when an edit cleared a prior approval and it has not been re-approved
   * yet. Drives the persistent, non-dismissable "approval revoked" notice.
   */
  approvalRevoked: boolean;
}

export function initialState(subject: string, body: string): DraftState {
  return { status: "proposed", subject, body, approvalRevoked: false };
}

/**
 * Editing the subject. Any payload change can revoke an approval.
 *
 * A rejected draft is refused here, before the copy: `applyEdit` only sees the already-edited
 * copy, so leaving the check to it returned that copy — still `rejected`, but with a payload
 * nobody reviewed. The UI disables the fields, but the machine is the invariant, not the UI.
 */
export function editSubject(s: DraftState, subject: string): DraftState {
  if (subject === s.subject || s.status === "rejected") return s;
  return applyEdit({ ...s, subject });
}

/** Editing the body. Any payload change can revoke an approval. */
export function editBody(s: DraftState, body: string): DraftState {
  if (body === s.body || s.status === "rejected") return s;
  return applyEdit({ ...s, body });
}

/**
 * Shared edit consequence: a payload change moves the action back to `edited`.
 * If it was `approved`, the approval is invalidated and the revoke notice shows
 * until the draft is preflighted and approved again. A draft that was only
 * `proposed`/`edited` just stays `edited`.
 */
function applyEdit(s: DraftState): DraftState {
  if (s.status === "rejected") return s; // a rejected draft is terminal this round
  const wasApproved = s.status === "approved";
  return {
    ...s,
    status: "edited",
    approvalRevoked: s.approvalRevoked || wasApproved,
  };
}

/** Run preflight. Only from proposed/edited — never a no-op path to approval. */
export function preflight(s: DraftState): DraftState {
  if (s.status === "proposed" || s.status === "edited") {
    return { ...s, status: "preflighted" };
  }
  return s;
}

/** Approve. ONLY reachable from preflighted — this is the invariant. */
export function approve(s: DraftState): DraftState {
  if (s.status === "preflighted") {
    return { ...s, status: "approved", approvalRevoked: false };
  }
  return s;
}

/** Reject — local terminal state; nothing sends this round. */
export function reject(s: DraftState): DraftState {
  return { ...s, status: "rejected" };
}

/** Whether the Preflight control is enabled for this state. */
export function canPreflight(s: DraftState): boolean {
  return s.status === "proposed" || s.status === "edited";
}

/** Whether the Approve control is enabled — preflighted only. */
export function canApprove(s: DraftState): boolean {
  return s.status === "preflighted";
}

const LABEL: Record<DraftStatus, string> = {
  proposed: "Proposed",
  edited: "Edited",
  preflighted: "Preflighted",
  approved: "Approved",
  rejected: "Rejected",
};

export function statusLabel(status: DraftStatus): string {
  return LABEL[status];
}
