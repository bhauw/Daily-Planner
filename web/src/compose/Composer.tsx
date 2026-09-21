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
 */

import { useMemo, useRef, useState, type FormEvent } from "react";
import { Button } from "../components/Button";
import { ApiError, type SendMailRequest, type SendMailResponse } from "../api/client";
import type { ComposePrefill } from "./types";

type Phase = "write" | "review" | "sending" | "sent";

interface ComposerProps {
  prefill: ComposePrefill;
  send: (request: SendMailRequest) => Promise<SendMailResponse>;
  onClose: () => void;
  /** True while a send is in flight, so the host can refuse to close over it. */
  onBusyChange?: (busy: boolean) => void;
  /** Called once, after the message is actually away. */
  onWrote?: () => void;
}

/** Split a recipients field the way people actually type one. */
export function parseRecipients(value: string): string[] {
  return value
    .split(/[,;\n]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

export function Composer({ prefill, send, onClose, onBusyChange, onWrote }: ComposerProps) {
  const [to, setTo] = useState(prefill.to.join(", "));
  const [cc, setCc] = useState((prefill.cc ?? []).join(", "));
  const [bcc, setBcc] = useState("");
  const [showCopies, setShowCopies] = useState((prefill.cc ?? []).length > 0);
  const [subject, setSubject] = useState(prefill.subject);
  const [body, setBody] = useState(prefill.body ?? "");
  const [phase, setPhase] = useState<Phase>("write");
  const [error, setError] = useState<string | null>(null);
  const bodyRef = useRef<HTMLTextAreaElement>(null);

  const recipients = useMemo(() => parseRecipients(to), [to]);
  const ccList = useMemo(() => parseRecipients(cc), [cc]);
  const bccList = useMemo(() => parseRecipients(bcc), [bcc]);
  const ready = recipients.length > 0 && subject.trim().length > 0 && body.trim().length > 0;

  function review(event?: FormEvent) {
    event?.preventDefault();
    if (!ready) return;
    setError(null);
    setPhase("review");
  }

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
      onWrote?.();
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
        <h2 className="compose__title">Send this?</h2>
        <p className="compose__lede">This goes out as soon as you press Send. It cannot be recalled.</p>

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

      <label className="compose__field compose__field--grow">
        <span className="compose__label">Message</span>
        <textarea
          ref={bodyRef}
          className="compose__textarea"
          value={body}
          onChange={(e) => setBody(e.target.value)}
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
        <Button onClick={onClose}>Cancel</Button>
        <span className="compose__spacer" />
        <span className="compose__hint" aria-hidden="true">⌘↵</span>
        <Button variant="primary" type="submit" disabled={!ready}>Review</Button>
      </div>
    </form>
  );
}
