/*
 * DraftEditor — the workbench's centre pane: edit the draft and drive its
 * action through the state machine.
 *
 * Editable: subject, body. Everything else is a REVIEW field — recipients,
 * attachments, target labels — shown in full and never inline-editable, because
 * a wrong recipient is the exact class of mistake this screen exists to prevent.
 *
 * Two persistent, non-dismissable notices live here:
 *   1. an irreversible-send warning for any draft whose action sends (--warn);
 *   2. an approval-revoked notice whenever an edit cleared a prior approval.
 * Neither can be dismissed — they clear only when the underlying state changes.
 *
 * This round is read-only: Preflight/Approve/Reject move LOCAL state only. No
 * write endpoint is called; the footer states that no external action occurred.
 */

import { Button } from "../contract";
import { WarnIcon, LockIcon, CheckIcon } from "./icons";
import { isSendAction, type DraftDetail } from "./data";
import {
  canApprove,
  canPreflight,
  statusLabel,
  type DraftState,
  type DraftStatus,
} from "./machine";
import type { Draft } from "../contract";

interface DraftEditorProps {
  draft: Draft;
  detail: DraftDetail;
  state: DraftState;
  onEditSubject: (v: string) => void;
  onEditBody: (v: string) => void;
  onPreflight: () => void;
  onApprove: () => void;
  onReject: () => void;
}

const STEPS: DraftStatus[] = ["proposed", "edited", "preflighted", "approved"];

export function DraftEditor({
  draft,
  detail,
  state,
  onEditSubject,
  onEditBody,
  onPreflight,
  onApprove,
  onReject,
}: DraftEditorProps) {
  const send = isSendAction(draft.kind);
  const rejected = state.status === "rejected";
  const revoked = state.approvalRevoked && state.status !== "approved";

  return (
    <div className="editor">
      <div className="editor__statusbar">
        <StatusStepper status={state.status} />
      </div>

      {/* Persistent, non-dismissable notices */}
      {send && (
        <div className="notice notice--warn" role="note" aria-label="This action sends an email">
          <WarnIcon className="notice__ic" />
          <span>
            This draft sends an email. <strong>Sending cannot be undone.</strong> Review the
            recipients below before you approve.
          </span>
        </div>
      )}
      {revoked && (
        <div className="notice notice--warn" role="alert">
          <WarnIcon className="notice__ic" />
          <span>
            You changed this draft after approving it, so the approval was cleared. Run preflight and
            approve again before it could ever be sent.
          </span>
        </div>
      )}

      {/* Immutable review fields */}
      <section className="review" aria-label="Review fields (not editable)">
        <div className="review__head">
          <LockIcon className="review__lock" />
          <span>Review fields — displayed, not editable</span>
        </div>
        <RecipientRow label="To" people={detail.to} emptyNote={send ? "No recipient" : "—"} />
        {detail.cc.length > 0 && <RecipientRow label="Cc" people={detail.cc} />}
        {detail.bcc.length > 0 && <RecipientRow label="Bcc" people={detail.bcc} />}
        {detail.attachments.length > 0 && (
          <div className="review__row">
            <span className="review__key">Attachments</span>
            <span className="review__val">
              {detail.attachments.map((a) => (
                <span key={a.name} className="chip chip--file">
                  {a.name} <span className="num chip__size">{a.size}</span>
                </span>
              ))}
            </span>
          </div>
        )}
        {detail.labels.length > 0 && (
          <div className="review__row">
            <span className="review__key">Labels</span>
            <span className="review__val">
              {detail.labels.map((l) => (
                <span key={l} className="chip">
                  {l}
                </span>
              ))}
            </span>
          </div>
        )}
      </section>

      {/* Payload. A real inbox thread has no drafted reply, so it is shown read-only and
          plainly labelled rather than dressed up as something approvable. */}
      {detail.isTriage ? (
        <div className="field field--grow">
          <span className="field__label">Thread</span>
          <p className="triage__snippet">{detail.snippet}</p>
          <p className="triage__notice" role="note">
            No reply has been drafted for this thread. This round reads your inbox so you can
            triage it — drafting and sending arrive in a later milestone.
          </p>
        </div>
      ) : (
        <>
          <div className="field">
            <label className="field__label" htmlFor="draft-subject">
              Subject
            </label>
            <input
              id="draft-subject"
              className="field__input"
              type="text"
              value={state.subject}
              disabled={rejected}
              onChange={(e) => onEditSubject(e.target.value)}
            />
          </div>
          <div className="field field--grow">
            <label className="field__label" htmlFor="draft-body">
              Body
            </label>
            <textarea
              id="draft-body"
              className="field__textarea"
              value={state.body}
              disabled={rejected}
              onChange={(e) => onEditBody(e.target.value)}
              spellCheck
            />
          </div>
        </>
      )}

      {/* Action footer */}
      <div className="editor__actions">
        <div className="editor__actions-left">
          <Button
            variant="default"
            onClick={onPreflight}
            disabled={!canPreflight(state) || rejected || detail.isTriage}
          >
            Preflight
          </Button>
          <Button
            variant="primary"
            onClick={onApprove}
            disabled={!canApprove(state) || rejected || detail.isTriage}
            icon={<CheckIcon />}
          >
            Approve
          </Button>
          <Button variant="ghost" onClick={onReject} disabled={rejected}>
            Reject
          </Button>
        </div>
        <div className="editor__actions-note num" aria-live="polite">
          {footerNote(state.status)}
        </div>
      </div>
    </div>
  );
}

function footerNote(status: DraftStatus): string {
  switch (status) {
    case "approved":
      return "Approved locally · nothing was sent";
    case "rejected":
      return "Rejected locally · nothing was sent";
    case "preflighted":
      return "Preflight passed · ready to approve";
    case "edited":
      return "Edited · preflight required";
    case "proposed":
      return "Proposed · preflight required";
  }
}

function RecipientRow({
  label,
  people,
  emptyNote,
}: {
  label: string;
  people: { name: string; address: string }[];
  emptyNote?: string;
}) {
  return (
    <div className="review__row">
      <span className="review__key">{label}</span>
      <span className="review__val">
        {people.length === 0 ? (
          <span className="review__empty">{emptyNote ?? "—"}</span>
        ) : (
          people.map((r) => (
            // Full address, never truncated into ambiguity.
            <span key={r.address} className="recipient">
              <span className="recipient__name">{r.name}</span>
              <span className="recipient__addr">&lt;{r.address}&gt;</span>
            </span>
          ))
        )}
      </span>
    </div>
  );
}

function StatusStepper({ status }: { status: DraftStatus }) {
  if (status === "rejected") {
    return (
      <div className="stepper stepper--rejected" aria-label="Action status: rejected">
        <span className="stepper__rejected">Rejected</span>
      </div>
    );
  }
  const currentIndex = STEPS.indexOf(status);
  return (
    <ol className="stepper" aria-label={`Action status: ${statusLabel(status)}`}>
      {STEPS.map((step, i) => {
        const done = i < currentIndex;
        const active = i === currentIndex;
        return (
          <li
            key={step}
            className={["stepper__step", done ? "is-done" : "", active ? "is-active" : ""]
              .filter(Boolean)
              .join(" ")}
            aria-current={active ? "step" : undefined}
          >
            <span className="stepper__dot" aria-hidden="true" />
            <span className="stepper__label">{statusLabel(step)}</span>
          </li>
        );
      })}
    </ol>
  );
}
