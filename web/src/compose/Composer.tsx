/*
 * The mail composer. Full To / Cc / Bcc / Subject / Body, sent from inside the
 * app — no handoff to Gmail.
 *
 * Two phases, on purpose. Sending is the one thing in this app that cannot be
 * undone, so the button labelled "Send" is never the one you are already
 * resting on: you write, you press Review, you see exactly who it is going to,
 * and then you send. Everything else in the app does its thing immediately.
 *
 * The review screen shows the recipients as a list rather than a joined string,
 * because "who is this actually going to" is the question the step exists to
 * answer, and a run-on line of addresses is the shape that hides an extra one.
 *
 * An assistant can propose the body, and that happens HERE rather than before
 * the composer opens. Three reasons: there is no dead time staring at a row
 * that has not become a dialog yet, a failure to draft does not stop you
 * writing the reply yourself, and the text lands in the field you were going
 * to edit it in anyway. Drafting replaces nothing and sends nothing — it fills
 * a textarea, and the Review step is still the only way anything leaves.
 */

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { Button } from "../components/Button";
import {
  ApiError,
  type DraftReplyRequest,
  type DraftReplyResponse,
  type ReplyIntent,
  type SendMailRequest,
  type SendMailResponse,
  type WeekResponse,
} from "../api/client";
import { FREE_FORM_INTENT, type ComposePrefill, type Written } from "./types";
import { isNoReplyAddress } from "../surfaces/mailTriage";
import { OfferTimes } from "./OfferTimes";

/**
 * What you can ask for, and what the button says.
 *
 * Buttons for the six ordinary cases, and a box for when none of them is what you meant.
 *
 * The buttons were a closed set rather than a free-text instruction box. The intent becomes part of what is
 * sent off the machine, and a text field here would be one more thing going straight into a
 * prompt — with no benefit, because these are the six things a reply to an inbox actually does.
 */
/** Matches PlannerReplyRequest.maxInstructionBytes, so the engine never has to refuse one. */
const MAX_INSTRUCTION = 1000;

const INTENTS: { intent: ReplyIntent; label: string }[] = [
  { intent: "accept", label: "Accept" },
  { intent: "decline", label: "Decline" },
  { intent: "reschedule", label: "Ask to move it" },
  { intent: "acknowledge", label: "Acknowledge" },
  { intent: "askQuestion", label: "Ask a question" },
  { intent: "followUp", label: "Follow up" },
];

type Phase = "write" | "review" | "sending" | "sent";

interface ComposerProps {
  prefill: ComposePrefill;
  send: (request: SendMailRequest) => Promise<SendMailResponse>;
  /** Asks an assistant for a body. Absent when none is configured. */
  draft?: (request: DraftReplyRequest) => Promise<DraftReplyResponse>;
  /** Named on the button, so it always says WHICH assistant is about to see the message. */
  draftProvider?: string;
  /** True when drafting sends the message off this Mac. The warning depends on it. */
  draftLeavesMachine?: boolean;
  /**
   * Reads the week, for "Offer times". Absent, the chip is not shown: without a calendar behind
   * it the picker could only invent times.
   */
  readWeek?: () => Promise<WeekResponse>;
  onClose: () => void;
  /** True while a send is in flight, so the host can refuse to close over it. */
  onBusyChange?: (busy: boolean) => void;
  /**
   * Hands the host a guard to call before it closes the panel (Escape, a backdrop click). The
   * guard returns true when closing loses nothing; otherwise it asks, in the panel, and returns
   * false. `onClose` itself always closes — it is what the Discard button calls.
   */
  registerCloseGuard?: (guard: (() => boolean) | null) => void;
  /** Called once, after the message is actually away, saying which message it answered. */
  onWrote?: (written: Written) => void;
}

/** Split a recipients field the way people actually type one. */
export function parseRecipients(value: string): string[] {
  return value
    .split(/[,;\n]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

export function Composer({
  prefill,
  send,
  draft,
  draftProvider,
  draftLeavesMachine = false,
  readWeek,
  onClose,
  onBusyChange,
  onWrote,
  registerCloseGuard,
}: ComposerProps) {
  const [to, setTo] = useState(prefill.to.join(", "));
  const [cc, setCc] = useState((prefill.cc ?? []).join(", "));
  const [bcc, setBcc] = useState("");
  const [showCopies, setShowCopies] = useState((prefill.cc ?? []).length > 0);
  const [subject, setSubject] = useState(prefill.subject);
  const [body, setBody] = useState(prefill.body ?? "");
  const [phase, setPhase] = useState<Phase>("write");
  const [error, setError] = useState<string | null>(null);
  const bodyRef = useRef<HTMLTextAreaElement>(null);
  // Where the write->review swap sends focus. The whole form unmounts and compose__review
  // mounts in its place, so without this a keyboard/screen-reader user is left on <body> with
  // no sign the screen changed — mirrors bodyRef's focus() after a draft lands, above.
  const reviewHeadingRef = useRef<HTMLHeadingElement>(null);
  // "custom" is not an intent — it marks the typed-instruction button as the one that is busy,
  // so only that control shows "Writing…" rather than all seven at once.
  const [drafting, setDrafting] = useState<ReplyIntent | "custom" | "offer" | null>(null);
  const [offering, setOffering] = useState(false);
  const [draftNote, setDraftNote] = useState<string | null>(null);
  const [undo, setUndo] = useState<string | null>(null);
  // The message is locked while drafting, so focus can only move into it once it is unlocked.
  const focusBodyNext = useRef(false);
  useEffect(() => {
    if (drafting == null && focusBodyNext.current) {
      focusBodyNext.current = false;
      bodyRef.current?.focus();
    }
  }, [drafting]);

  // Offered only when there is an assistant AND a message to draft against. Generating a reply
  // to nothing is not a thing this can do.
  const canDraft = draft != null && prefill.draftFrom != null;
  // Kept even after a draft lands, so "make it shorter" is one edit away from "make it warmer"
  // rather than something to retype.
  const [instruction, setInstruction] = useState("");

  const recipients = useMemo(() => parseRecipients(to), [to]);
  const ccList = useMemo(() => parseRecipients(cc), [cc]);
  const bccList = useMemo(() => parseRecipients(bcc), [bcc]);
  /*
   * Esc, Cancel or a backdrop click used to throw a half-written reply away without a word. Now
   * a body that differs from what the composer opened with asks first. The ask lives inside the
   * panel rather than in `window.confirm`: WKWebView shows that only if the host implements a UI
   * delegate for it, and otherwise returns false without showing anything.
   */
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const dirty = body !== (prefill.body ?? "") && body.trim().length > 0;
  const guardState = useRef({ dirty, phase });
  guardState.current = { dirty, phase };
  const guardRef = useRef(() => {
    const { dirty: isDirty, phase: now } = guardState.current;
    if (now === "sent" || !isDirty) return true;
    setConfirmDiscard(true);
    return false;
  });
  useEffect(() => {
    registerCloseGuard?.(guardRef.current);
    return () => registerCloseGuard?.(null);
  }, [registerCloseGuard]);

  function cancel() {
    if (guardRef.current()) onClose();
  }

  const discardBar = confirmDiscard ? (
    <div className="compose__discard" role="alertdialog" aria-label="Discard this reply?">
      <p className="compose__error">Discard this reply? What you wrote will be lost.</p>
      <div className="compose__actions">
        <Button
          onClick={() => {
            setConfirmDiscard(false);
            bodyRef.current?.focus();
          }}
        >
          Keep writing
        </Button>
        <span className="compose__spacer" />
        <Button variant="primary" onClick={onClose}>Discard</Button>
      </div>
    </div>
  ) : null;

  const noReplyRecipients = useMemo(
    () => [...recipients, ...ccList, ...bccList].filter(isNoReplyAddress),
    [recipients, ccList, bccList],
  );
  const ready = recipients.length > 0 && subject.trim().length > 0 && body.trim().length > 0;

  async function proposeBody(
    intent: ReplyIntent,
    instruction?: string,
    via: "custom" | "offer" = "custom",
  ): Promise<boolean> {
    if (!draft || !prefill.draftFrom) return false;
    setDrafting(instruction ? via : intent);
    setDraftNote(null);
    setError(null);
    const before = body;
    try {
      const proposal = await draft({ messageId: prefill.draftFrom, intent, instruction });
      setBody(proposal.body);
      // Drafting used to replace what he had written with no way back. The old text is kept
      // for one click, until he edits the new one.
      setUndo(before.trim() && before !== proposal.body ? before : null);
      setDraftNote(`Drafted by ${proposal.provider}. Read it before you send it.`);
      focusBodyNext.current = true;
      return true;
    } catch (failure) {
      // A drafting failure must not be a dead end: the reply can still be typed. So this is a
      // note beside the field, not the form's error state.
      setDraftNote(
        failure instanceof ApiError ? failure.message : "The assistant could not be reached.",
      );
      return false;
    } finally {
      setDrafting(null);
    }
  }

  function review(event?: FormEvent) {
    event?.preventDefault();
    if (!ready) return;
    setError(null);
    setPhase("review");
  }

  // The review screen's heading takes focus the moment it mounts, so the swap reads as a
  // navigation rather than a silent drop to <body>.
  useEffect(() => {
    if (phase === "review") reviewHeadingRef.current?.focus();
  }, [phase]);

  async function confirmSend() {
    setPhase("sending");
    onBusyChange?.(true);
    setError(null);
    try {
      await send({
        to: recipients,
        ...(ccList.length > 0 ? { cc: ccList } : {}),
        ...(bccList.length > 0 ? { bcc: bccList } : {}),
        subject: subject.trim(),
        body,
        ...(prefill.threadId ? { threadId: prefill.threadId } : {}),
        ...(prefill.inReplyTo ? { inReplyTo: prefill.inReplyTo } : {}),
      });
      setPhase("sent");
      onBusyChange?.(false);
      onWrote?.({ kind: "mail", ...(prefill.answers ? { answers: prefill.answers } : {}) });
    } catch (failure) {
      // Back to review, not to the form: the message is intact and the user is one press from
      // trying again or going back to edit. Nothing here retries on its own — a send that may
      // have gone through must not be repeated on the user's behalf.
      setPhase("review");
      onBusyChange?.(false);
      setError(
        failure instanceof ApiError ? failure.message : "That could not be sent. Nothing was sent.",
      );
    }
  }

  if (phase === "sent") {
    return (
      <div className="compose__done" role="status">
        <div className="compose__donemark" aria-hidden="true">✓</div>
        <h2 className="compose__donetitle">Sent</h2>
        <p className="compose__donedetail">
          Your message went to {recipients.length === 1 ? recipients[0] : `${recipients.length} recipients`}.
        </p>
        <Button variant="primary" onClick={onClose}>Done</Button>
      </div>
    );
  }

  if (phase === "review" || phase === "sending") {
    const busy = phase === "sending";
    return (
      <div className="compose__review">
        {discardBar}
        <h2 className="compose__title" ref={reviewHeadingRef} tabIndex={-1}>Send this?</h2>
        <p className="compose__lede">This goes out as soon as you press Send. It cannot be recalled.</p>
        {/*
          * Said here, on the screen that exists to answer "who is this going to", because a
          * reply to no-reply@ used to go out without a word and reach nobody.
          */}
        {noReplyRecipients.length > 0 && (
          <p className="compose__error" role="alert">
            {noReplyRecipients.join(", ")} does not accept replies. Nobody will read this.
          </p>
        )}

        <dl className="compose__summary">
          <dt>To</dt>
          <dd>
            <ul className="compose__addrs">
              {recipients.map((address) => <li key={address}>{address}</li>)}
            </ul>
          </dd>
          {ccList.length > 0 && (
            <>
              <dt>Cc</dt>
              <dd><ul className="compose__addrs">{ccList.map((a) => <li key={a}>{a}</li>)}</ul></dd>
            </>
          )}
          {bccList.length > 0 && (
            <>
              <dt>Bcc</dt>
              <dd><ul className="compose__addrs">{bccList.map((a) => <li key={a}>{a}</li>)}</ul></dd>
            </>
          )}
          <dt>Subject</dt>
          <dd>{subject.trim()}</dd>
        </dl>

        <pre className="compose__preview">{body}</pre>

        {error && <p className="compose__error" role="alert">{error}</p>}

        <div className="compose__actions">
          <Button onClick={() => setPhase("write")} disabled={busy}>Back to edit</Button>
          <span className="compose__spacer" />
          <Button variant="primary" onClick={() => void confirmSend()} disabled={busy}>
            {busy ? "Sending…" : "Send"}
          </Button>
        </div>
      </div>
    );
  }

  return (
    <form className="compose__form" onSubmit={review}>
      {discardBar}
      <h2 className="compose__title">New message</h2>
      {prefill.context && <p className="compose__context">Replying to {prefill.context}</p>}

      <label className="compose__field">
        <span className="compose__label">To</span>
        <input
          className="compose__input"
          value={to}
          onChange={(e) => setTo(e.target.value)}
          placeholder="name@example.com"
          autoComplete="off"
          autoFocus={prefill.to.length === 0}
        />
      </label>

      {showCopies ? (
        <>
          <label className="compose__field">
            <span className="compose__label">Cc</span>
            <input className="compose__input" value={cc} onChange={(e) => setCc(e.target.value)} autoComplete="off" />
          </label>
          <label className="compose__field">
            <span className="compose__label">Bcc</span>
            <input className="compose__input" value={bcc} onChange={(e) => setBcc(e.target.value)} autoComplete="off" />
          </label>
        </>
      ) : (
        <button type="button" className="compose__more" onClick={() => setShowCopies(true)}>
          Add Cc or Bcc
        </button>
      )}

      <label className="compose__field">
        <span className="compose__label">Subject</span>
        <input
          className="compose__input"
          value={subject}
          onChange={(e) => setSubject(e.target.value)}
          autoComplete="off"
        />
      </label>

      {canDraft && (
        <div className="compose__assist">
          <span className="compose__label">
            Draft it for me
            {draftProvider && <span className="compose__optional">{draftProvider}</span>}
          </span>
          <div className="compose__quick" role="group" aria-label="Draft a reply">
            {INTENTS.map(({ intent, label }) => (
              <button
                key={intent}
                type="button"
                className="compose__chip"
                disabled={drafting != null}
                onClick={() => void proposeBody(intent)}
              >
                {drafting === intent ? "Writing…" : label}
              </button>
            ))}
            {readWeek && (
              <button
                type="button"
                className={["compose__chip", offering ? "compose__chip--on" : ""].filter(Boolean).join(" ")}
                aria-expanded={offering}
                disabled={drafting != null}
                onClick={() => setOffering((v) => !v)}
              >
                Offer times
              </button>
            )}
          </div>
          {/*
            The same picker the Mail workbench opens. Times go in as the instruction on the
            followUp intent (the engine uses the instruction in place of the intent's wording),
            and the draft lands in Message below — Review, then Send, is still the only way out.
          */}
          {offering && readWeek && (
            <OfferTimes
              readWeek={readWeek}
              onDraft={async (built) => {
                if (await proposeBody("followUp", built, "offer")) setOffering(false);
              }}
              onCancel={() => setOffering(false)}
              disabled={drafting != null && drafting !== "offer"}
            />
          )}
          {/*
            Said before it happens, not after. Pressing one of those buttons is the moment this
            message goes to someone else's computer, and the person pressing it should know
            that from the screen rather than from a changelog.
          */}
          <p className="compose__assistnote">
            {draftLeavesMachine
              ? "This sends the subject, the sender and the snippet to the assistant. Nothing is emailed until you press Review, then Send."
              : "This runs on your Mac. Nothing is emailed until you press Review, then Send."}
          </p>
          {/*
            The escape hatch. Six buttons cover the ordinary cases; everything else — "say I can
            do Tuesday but not Thursday", "keep it formal, they are a partner" — used to mean
            picking the nearest wrong one and rewriting the result by hand.
          */}
          <div className="compose__custom">
            <label className="sr-only" htmlFor="draft-instruction">
              Tell the assistant what to write
            </label>
            <input
              id="draft-instruction"
              className="compose__custominput"
              type="text"
              placeholder="Or tell it what to say…"
              value={instruction}
              maxLength={MAX_INSTRUCTION}
              disabled={drafting != null}
              onChange={(e) => setInstruction(e.target.value)}
              onKeyDown={(e) => {
                // Enter drafts; it must not reach the form, where it would mean "review".
                if (e.key !== "Enter") return;
                e.preventDefault();
                e.stopPropagation();
                if (instruction.trim()) void proposeBody(FREE_FORM_INTENT, instruction.trim());
              }}
            />
            <Button
              type="button"
              size="sm"
              variant="default"
              disabled={drafting != null || instruction.trim().length === 0}
              onClick={() => void proposeBody(FREE_FORM_INTENT, instruction.trim())}
            >
              {drafting === "custom" ? "Writing…" : "Write it"}
            </Button>
          </div>
          {draftNote && (
            <p className="compose__assistnote compose__assistnote--said" role="status">
              {draftNote}
            </p>
          )}
          {undo != null && drafting == null && (
            <button
              type="button"
              className="compose__more"
              onClick={() => {
                setBody(undo);
                setUndo(null);
                setDraftNote("Your own text is back.");
                bodyRef.current?.focus();
              }}
            >
              Undo
            </button>
          )}
        </div>
      )}

      <label className="compose__field compose__field--grow">
        <span className="compose__label">Message</span>
        <textarea
          ref={bodyRef}
          className="compose__textarea"
          value={body}
          // Locked while a draft is written: anything typed now would be replaced when it lands.
          disabled={drafting != null}
          onChange={(e) => {
            setUndo(null);
            setBody(e.target.value);
          }}
          rows={12}
          autoFocus={prefill.to.length > 0}
          // ⌘↵ from the body goes to review, not to send. The shortcut that skips
          // straight to sending is the one that sends the half-written message.
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              review();
            }
          }}
        />
      </label>

      <div className="compose__actions">
        <Button onClick={cancel}>Cancel</Button>
        <span className="compose__spacer" />
        <span className="compose__hint" aria-hidden="true">⌘↵</span>
        <Button variant="primary" type="submit" disabled={!ready}>Review</Button>
      </div>
    </form>
  );
}
