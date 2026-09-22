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

import { useState } from "react";
import { Button } from "../contract";
import type { ReplyIntent } from "../contract";
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
  /**
   * Asks the engine for a proposal. Absent when no assistant is configured, which is what
   * makes "this cannot generate" a structural fact rather than a disabled button.
   */
  onDraft?: (messageId: string, intent: ReplyIntent, instruction?: string) => Promise<string>;
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
  onDraft,
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
          {/*
            This used to say drafting "arrives in a later milestone". It arrived. A message
            that outlives the thing it describes is worse than no message, because it tells
            someone a feature they are looking at does not exist yet.
          */}
          <ReplyBox
            draftId={draft.id}
            body={state.body}
            disabled={rejected}
            onEditBody={onEditBody}
            onDraft={onDraft}
          />
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

/*
 * Draft a reply to a real inbox thread, in the pane where the thread is.
 *
 * The workbench used to be triage-only: it showed what arrived and told you drafting existed
 * somewhere else. Reading a message and answering it are one action, so the answer belongs
 * next to the thing being answered rather than behind a navigation step.
 *
 * Six buttons for the ordinary cases and a box for everything else — the same pair the composer
 * offers, because two places that draft replies should not disagree about how.
 */
const INTENTS: { intent: ReplyIntent; label: string }[] = [
  { intent: "accept", label: "Accept" },
  { intent: "decline", label: "Decline" },
  { intent: "reschedule", label: "Ask to move it" },
  { intent: "acknowledge", label: "Acknowledge" },
  { intent: "askQuestion", label: "Ask a question" },
  { intent: "followUp", label: "Follow up" },
];

/** Matches PlannerReplyRequest.maxInstructionBytes, so the engine never has to refuse one. */
const MAX_INSTRUCTION = 1000;

function ReplyBox({
  draftId,
  body,
  disabled,
  onEditBody,
  onDraft,
}: {
  draftId: string;
  body: string;
  disabled: boolean;
  onEditBody: (v: string) => void;
  onDraft?: (messageId: string, intent: ReplyIntent, instruction?: string) => Promise<string>;
}) {
  const [busy, setBusy] = useState<ReplyIntent | "custom" | null>(null);
  const [instruction, setInstruction] = useState("");
  const [note, setNote] = useState<string | null>(null);

  if (!onDraft) {
    return (
      <p className="triage__notice" role="note">
        No assistant is configured, so nothing can be drafted here. You can still write a reply
        yourself once sending is enabled.
      </p>
    );
  }

  async function propose(intent: ReplyIntent, typed?: string) {
    setBusy(typed ? "custom" : intent);
    setNote(null);
    try {
      const proposed = await onDraft!(draftId, intent, typed);
      onEditBody(proposed);
      setNote("Drafted for you. Read it before you approve it.");
    } catch (failure) {
      // A failure must not be a dead end — the reply can still be typed by hand.
      setNote(failure instanceof Error ? failure.message : "The assistant could not be reached.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="reply">
      <div className="reply__head">
        <span className="field__label">Your reply</span>
        <span className="reply__hint">Nothing is sent until you approve it.</span>
      </div>

      <div className="reply__quick" role="group" aria-label="Draft a reply">
        {INTENTS.map(({ intent, label }) => (
          <button
            key={intent}
            type="button"
            className="compose__chip"
            disabled={busy != null || disabled}
            onClick={() => void propose(intent)}
          >
            {busy === intent ? "Writing…" : label}
          </button>
        ))}
      </div>

      <div className="reply__custom">
        <label className="sr-only" htmlFor={`reply-instruction-${draftId}`}>
          Tell the assistant what to write
        </label>
        <input
          id={`reply-instruction-${draftId}`}
          className="compose__custominput"
          type="text"
          placeholder="Or tell it what to say…"
          value={instruction}
          maxLength={MAX_INSTRUCTION}
          disabled={busy != null || disabled}
          onChange={(e) => setInstruction(e.target.value)}
          onKeyDown={(e) => {
            if (e.key !== "Enter") return;
            e.preventDefault();
            if (instruction.trim()) void propose("accept", instruction.trim());
          }}
        />
        <Button
          type="button"
          size="sm"
          variant="default"
          disabled={busy != null || disabled || instruction.trim().length === 0}
          onClick={() => void propose("accept", instruction.trim())}
        >
          {busy === "custom" ? "Writing…" : "Write it"}
        </Button>
      </div>

      <textarea
        className="field__textarea reply__body"
        value={body}
        disabled={disabled}
        placeholder="Write your reply, or have it drafted above."
        onChange={(e) => onEditBody(e.target.value)}
        spellCheck
        aria-label="Your reply"
      />

      {note && (
        <p className="compose__assistnote compose__assistnote--said" role="status">
          {note}
        </p>
      )}
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
