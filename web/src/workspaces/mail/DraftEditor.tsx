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
 * Synthetic drafts: Preflight/Approve/Reject move LOCAL state only, and the footer
 * says no external action occurred. A REAL inbox thread instead offers "Review &
 * send", which opens the app's one composer prefilled with the reply — that
 * composer's own review step and Send are the only way anything leaves.
 */

import { useEffect, useRef, useState } from "react";
import { Button } from "../contract";
import type { ReplyIntent, WeekResponse } from "../contract";
import type { MailBody } from "../../api/client";
import { WarnIcon, LockIcon, CheckIcon } from "./icons";
import { MessageBody } from "./MessageBody";
import { BookIt } from "./BookIt";
import { OfferTimes } from "../../compose/OfferTimes";
import { useWriteDesk } from "../../compose/WriteDesk";
import { FREE_FORM_INTENT } from "../../compose/types";
import { replySubject } from "../../surfaces/actions";
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
  /** Puts a rejected draft back as it was. Absent when there is nothing to restore. */
  onUndoReject?: () => void;
  /**
   * Asks the engine for a proposal. Absent when no assistant is configured, which is what
   * makes "this cannot generate" a structural fact rather than a disabled button.
   */
  onDraft?: (messageId: string, intent: ReplyIntent, instruction?: string) => Promise<string>;
  /** Fetches the message's full body, to read. Absent when the engine cannot. */
  readBody?: (id: string) => Promise<MailBody>;
  /** Summarises it — the one call that sends the body off the machine. Absent with no assistant. */
  summarize?: (id: string) => Promise<{ summary: string; provider: string }>;
  /**
   * Reads the week, for "Offer times" to find his free slots in. Absent, the chip is not offered:
   * a picker with no calendar behind it could only invent times.
   */
  readWeek?: () => Promise<WeekResponse>;
  /** Which assistant drafts, and whether that sends the message off this Mac. With onDraft. */
  assistant?: { provider: string; leavesMachine: boolean };
  /** True once the engine has said there is no assistant (not merely while it is being asked). */
  assistantOff?: boolean;
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
  onUndoReject,
  onDraft,
  readBody,
  summarize,
  readWeek,
  assistant,
  assistantOff,
}: DraftEditorProps) {
  const send = isSendAction(draft.kind);
  const rejected = state.status === "rejected";
  const revoked = state.approvalRevoked && state.status !== "approved";
  const desk = useWriteDesk();
  // The warning that a send cannot be undone, only where something would be sent: a real thread
  // needs a reply worth sending, a written one, and a window that can send it.
  const warnSend = detail.isTriage
    ? detail.replyExpected && state.body.trim().length > 0 && desk != null
    : send;
  // A real thread is SENT through the app's one composer, which shows the finished message and
  // asks again before anything leaves. The workbench never sends by itself.
  const canSendReply = detail.isTriage && desk?.capability.canSend === true && Boolean(draft.sender);
  const canReview = canSendReply && !rejected && state.body.trim().length > 0;
  function reviewAndSend() {
    desk!.compose({
      to: [draft.sender!],
      subject: replySubject(draft.title),
      body: state.body,
      ...(draft.threadId ? { threadId: draft.threadId } : {}),
      context: draft.sender!,
    });
  }
  // What the email pane is showing, for the booking offer to read, and whether he has just
  // drafted a yes. Both belong to ONE message and are cleared when another is selected.
  //
  // `accepted` is stored WITH the id it was drafted for. A draft that lands after he has moved to
  // another thread used to set it on whichever thread was showing, so the bank statement asked
  // "You're accepting — put it in your calendar?".
  const [shownText, setShownText] = useState(detail.snippet);
  const [acceptedFor, setAcceptedFor] = useState<string | null>(null);
  const accepted = acceptedFor === draft.id;
  useEffect(() => {
    setShownText(detail.snippet);
    setAcceptedFor(null);
  }, [draft.id, detail.snippet]);

  return (
    <div className="editor">
      {/*
        A real thread never goes through Preflight or Approve, so a Proposed → Approved stepper
        there described steps that do not exist — and took the height the email needs. Its
        status is still in the column header.
      */}
      {!detail.isTriage && (
        <div className="editor__statusbar">
          <StatusStepper status={state.status} />
        </div>
      )}

      {/* Persistent, non-dismissable notices */}
      {warnSend && (
        <div className="notice notice--warn" role="note" aria-label="This action sends an email">
          <WarnIcon className="notice__ic" />
          {/*
            A real thread has no Approve — its reply goes through Review & send — so it gets the
            one-line form: the same warning, without a step that does not exist there, and in a
            height a 768px-tall window can spare.
          */}
          {detail.isTriage ? (
            <span>
              This reply sends an email. <strong>Sending cannot be undone.</strong>
            </span>
          ) : (
            <span>
              This draft sends an email. <strong>Sending cannot be undone.</strong> Review the
              recipients below before you approve.
            </span>
          )}
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
      <section
        className={["review", detail.isTriage ? "review--thread" : ""].filter(Boolean).join(" ")}
        aria-label="Review fields (not editable)"
      >
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

      {/* Payload. A real inbox thread has no drafted reply, so the email itself is shown
          read-only and plainly labelled rather than dressed up as something approvable. */}
      {detail.isTriage ? (
        <div className="field field--grow field--triage">
          <MessageBody
            messageId={draft.id}
            snippet={detail.snippet}
            readBody={readBody}
            summarize={summarize}
            onShown={setShownText}
          />
          <BookIt
            text={shownText}
            subject={draft.title}
            receivedAt={draft.receivedAt}
            accepted={accepted}
          />
          {/*
            This used to say drafting "arrives in a later milestone". It arrived. A message
            that outlives the thing it describes is worse than no message, because it tells
            someone a feature they are looking at does not exist yet.
          */}
          {/*
            Keyed by thread: everything the box holds — a draft in flight ("Writing…"), the
            typed instruction, the note, the slot picker — belongs to ONE message. Unkeyed, all
            of it followed him to the next thread he selected.
          */}
          <ReplyBox
            key={draft.id}
            draftId={draft.id}
            body={state.body}
            disabled={rejected}
            onEditBody={onEditBody}
            onDraft={onDraft}
            readWeek={readWeek}
            assistant={assistant}
            assistantOff={assistantOff}
            onReview={canReview ? reviewAndSend : undefined}
            onDrafted={(forId, intent, typed) =>
              setAcceptedFor(isAgreeing(intent, typed) ? forId : null)
            }
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
        {detail.isTriage ? (
          <div className="editor__actions-left">
            <Button
              variant="primary"
              onClick={reviewAndSend}
              disabled={!canReview}
              icon={<CheckIcon />}
              aria-keyshortcuts="Meta+Enter"
            >
              Review &amp; send
            </Button>
            <span className="compose__hint" aria-hidden="true">⌘↵</span>
            {rejected && onUndoReject ? (
              <Button variant="ghost" onClick={onUndoReject}>
                Undo
              </Button>
            ) : (
              <Button variant="ghost" onClick={onReject} disabled={rejected}>
                Reject
              </Button>
            )}
          </div>
        ) : (
          <div className="editor__actions-left">
            <Button
              variant="default"
              onClick={onPreflight}
              disabled={!canPreflight(state) || rejected}
            >
              Preflight
            </Button>
            <Button
              variant="primary"
              onClick={onApprove}
              disabled={!canApprove(state) || rejected}
              icon={<CheckIcon />}
            >
              Approve
            </Button>
            {rejected && onUndoReject ? (
              <Button variant="ghost" onClick={onUndoReject}>
                Undo
              </Button>
            ) : (
              <Button variant="ghost" onClick={onReject} disabled={rejected}>
                Reject
              </Button>
            )}
          </div>
        )}
        <div className="editor__actions-note" aria-live="polite">
          {detail.isTriage ? triageNote(canSendReply, rejected, state.body, desk != null) : footerNote(state.status)}
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
  readWeek,
  assistant,
  assistantOff,
  onReview,
  onDrafted,
}: {
  draftId: string;
  body: string;
  disabled: boolean;
  onEditBody: (v: string) => void;
  onDraft?: (messageId: string, intent: ReplyIntent, instruction?: string) => Promise<string>;
  readWeek?: () => Promise<WeekResponse>;
  assistant?: { provider: string; leavesMachine: boolean };
  assistantOff?: boolean;
  /** Opens Review & send. Absent while it would be disabled. */
  onReview?: () => void;
  /** Told which kind of reply was just drafted, so the pane can offer to book an accepted one. */
  onDrafted?: (draftId: string, intent: ReplyIntent, typed?: string) => void;
}) {
  const [busy, setBusy] = useState<ReplyIntent | "custom" | "offer" | null>(null);
  const [instruction, setInstruction] = useState("");
  const [note, setNote] = useState<string | null>(null);
  // The slot picker is about ONE message. Selecting another thread closes it, so a picker opened
  // for the Example Consulting email can never draft its times into the reply to the registrar.
  const [offering, setOffering] = useState(false);
  useEffect(() => setOffering(false), [draftId]);
  // Compact until used: an empty text box does not get the email's height. See mail.css.
  const [focused, setFocused] = useState(false);
  const open = focused || busy != null || body.trim().length > 0;
  // Where focus goes while a draft is written, and after. See propose().
  const boxRef = useRef<HTMLDivElement>(null);
  const statusRef = useRef<HTMLParagraphElement>(null);
  const bodyRef = useRef<HTMLTextAreaElement>(null);
  // What he had written before a draft replaced it, so the replacement is one click from undone.
  // Drafting used to overwrite his own words silently, with no way back.
  const [undo, setUndo] = useState<string | null>(null);
  // The reply is locked while drafting, so focus can only move into it once it is unlocked.
  const focusReplyNext = useRef(false);
  // Whether this box is still on screen. It is keyed by thread, so leaving the thread unmounts it.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    if (busy == null && focusReplyNext.current) {
      focusReplyNext.current = false;
      bodyRef.current?.focus();
    }
  }, [busy]);

  async function propose(intent: ReplyIntent, typed?: string, via: "custom" | "offer" = "custom"): Promise<boolean> {
    // Every control here is disabled while a draft is written — including the one he just
    // pressed, which then cannot hold focus, so it fell to <body>. Focus moves to the status line
    // first (it says "Writing your reply…"), and to the reply once the draft is in it.
    const hadFocus = boxRef.current?.contains(document.activeElement) ?? false;
    setBusy(typed ? via : intent);
    setNote(null);
    if (hadFocus) statusRef.current?.focus();
    const before = body;
    try {
      const proposed = await onDraft!(draftId, intent, typed);
      // Landed after he left the thread: there is no Undo on screen to take it back with, so a
      // draft that would replace his own words is dropped. Into an empty reply it still lands.
      if (!mounted.current && before.trim()) return false;
      onEditBody(proposed);
      setUndo(before.trim() && before !== proposed ? before : null);
      if (hadFocus) focusReplyNext.current = true;
      // An offer of times is not a yes: the booking prompt stays quiet until he agrees to one.
      // Reported without its instruction, whose "do not say anything is booked" would otherwise
      // read as agreement to isAgreeing's "book".
      onDrafted?.(draftId, intent, via === "offer" ? undefined : typed);
      setNote("Drafted for you. Read it before you send it.");
      return true;
    } catch (failure) {
      // A failure must not be a dead end — the reply can still be typed by hand.
      setNote(failure instanceof Error ? failure.message : "The assistant could not be reached.");
      return false;
    } finally {
      setBusy(null);
    }
  }

  /*
   * Times go in as an instruction, on the `followUp` intent. The engine uses the instruction in
   * place of the intent's own wording, so the intent is only a label here — and followUp, not
   * accept, because offering times agrees to nothing yet. The picker closes once the draft lands,
   * so the reply it wrote is what fills the pane.
   */
  async function offerTimes(built: string) {
    if (await propose("followUp", built, "offer")) setOffering(false);
  }

  return (
    <div
      ref={boxRef}
      className={["reply", offering ? "reply--offering" : "", open ? "reply--open" : ""]
        .filter(Boolean)
        .join(" ")}
    >
      <div className="reply__head">
        <span className="field__label">Your reply</span>
        {/*
          Where his mail goes when he drafts, said before he presses anything — the same line
          the composer shows. "Nothing is sent" alone read as "nothing leaves", which is not true
          of a cloud assistant. (That nothing is emailed yet is the footer's line, beside the button
          that would do it.)
        */}
        <span className="reply__hint">
          {onDraft && assistant
            ? assistant.leavesMachine
              ? `Drafting sends the subject, the sender and the snippet to ${assistant.provider}.`
              : "Drafting runs on your Mac. Nothing is emailed until you review and send it."
            : "Nothing is sent until you review and send it."}
        </span>
      </div>

      {/*
        No assistant, no drafting controls — but the reply box stays: he can always write it
        himself. It used to be replaced by a notice, leaving nowhere to type at all.
      */}
      {assistantOff && (
        <p className="reply__hint" role="note">
          No assistant is on, so nothing is drafted here. Write the reply yourself.
        </p>
      )}

      {onDraft && (
      <>
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
        {readWeek && (
          <button
            type="button"
            className={["compose__chip", offering ? "compose__chip--on" : ""].filter(Boolean).join(" ")}
            aria-expanded={offering}
            disabled={busy != null || disabled}
            onClick={() => setOffering((v) => !v)}
          >
            Offer times
          </button>
        )}
      </div>

      {offering && readWeek && (
        <OfferTimes
          readWeek={readWeek}
          onDraft={offerTimes}
          onCancel={() => setOffering(false)}
          disabled={disabled || (busy != null && busy !== "offer")}
        />
      )}

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
            if (instruction.trim()) void propose(FREE_FORM_INTENT, instruction.trim());
          }}
        />
        <Button
          type="button"
          size="sm"
          variant="default"
          disabled={busy != null || disabled || instruction.trim().length === 0}
          onClick={() => void propose(FREE_FORM_INTENT, instruction.trim())}
        >
          {busy === "custom" ? "Writing…" : "Write it"}
        </Button>
      </div>

      </>
      )}

      <textarea
        ref={bodyRef}
        className="field__textarea reply__body"
        rows={1}
        value={body}
        // Locked while a draft is written: anything typed now would be replaced when it lands.
        disabled={disabled || busy != null}
        placeholder="Write your reply, or have it drafted above."
        onChange={(e) => {
          // Once he edits the draft, Undo would throw his edits away, so it goes.
          setUndo(null);
          onEditBody(e.target.value);
        }}
        // ⌘↵ goes to Review & send — the composer's review step, never straight to sending — the
        // same shortcut the composer's own body has, so it does one thing everywhere.
        onKeyDown={(e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && onReview) {
            e.preventDefault();
            onReview();
          }
        }}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        spellCheck
        aria-label="Your reply"
      />

      {/*
        Always rendered: a live region announces changes only to one that already exists, and
        this is also where focus waits while the draft is written. Visually hidden when empty.
      */}
      <p
        ref={statusRef}
        tabIndex={-1}
        className={busy != null || note ? "compose__assistnote compose__assistnote--said" : "sr-only"}
        role="status"
        aria-live="polite"
      >
        {busy != null ? "Writing your reply…" : note}
      </p>
      {undo != null && busy == null && (
        <button
          type="button"
          className="message__toggle"
          onClick={() => {
            onEditBody(undo);
            setUndo(null);
            setNote("Your own text is back.");
            bodyRef.current?.focus();
          }}
        >
          Undo
        </button>
      )}
    </div>
  );
}

/**
 * Whether a drafted reply says yes. The Accept button does; a typed instruction does when it
 * reads like agreement ("say Thursday works", "confirm the coffee chat"). A miss only means the
 * quieter "Dates in this email" row stays as it was.
 */
export function isAgreeing(intent: ReplyIntent, typed?: string): boolean {
  if (!typed) return intent === "accept";
  const t = typed.toLowerCase();
  if (/\b(decline|can'?t|cannot|won'?t|not able|unable|no\b)/.test(t)) return false;
  return /\b(accept|yes|sure|works|confirm|agree|book|see you|sounds good|happy to|i'?ll be there)\b/.test(t);
}

/** What the footer says for a real thread: where the reply goes next, or why it cannot. */
export function triageNote(canSend: boolean, rejected: boolean, body: string, hasDesk = true): string {
  if (rejected) return "Rejected locally · nothing was sent";
  // A detached window has no send window of its own. That is not the account's fault, and
  // telling him to "reconnect" sent him to fix something that was not broken.
  if (!hasDesk) return "Send it from the main window · this window reads and drafts";
  if (!canSend) return "This account is connected for reading only · reconnect to send";
  if (!body.trim()) return "Write or draft a reply to send it";
  return "Opens the send window · nothing goes until you press Send there";
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
            <span key={r.address || r.name} className="recipient">
              <span className="recipient__name">{r.name}</span>
              {/* A real thread knows only the sender line; an empty "<>" beside it read as a bug. */}
              {r.address && <span className="recipient__addr">&lt;{r.address}&gt;</span>}
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
