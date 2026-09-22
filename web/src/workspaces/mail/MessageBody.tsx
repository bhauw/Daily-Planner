/*
 * MessageBody — the email itself, in the pane where it is answered.
 *
 * Until this existed the middle pane showed the Gmail snippet, because a snippet was all the
 * engine had. It now fetches the one message being looked at, in full, and shows it as text.
 *
 * READING IS LOCAL. The body comes from Gmail to this page and goes nowhere else; drafting a
 * reply still sends only the subject, sender and snippet. SUMMARISING is the one thing that
 * sends the body, so it is a button that says so, never something that happens on open.
 *
 * THE SCROLL RULE. Only the thread list scrolls in this workspace. The body therefore CLAMPS,
 * and "Show whole email" opens it in place — and only while it is open does it get the one
 * scrollbar the middle pane is allowed. Braxton chose that over an always-on body scroller.
 */

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Button } from "../contract";
import type { MailBody } from "../../api/client";

type BodyState =
  | { status: "loading" }
  | { status: "ready"; body: MailBody }
  | { status: "failed" };

type SummaryState =
  | { status: "idle" }
  | { status: "busy" }
  | { status: "done"; text: string; provider: string }
  | { status: "failed"; message: string };

export function MessageBody({
  messageId,
  snippet,
  readBody,
  summarize,
}: {
  messageId: string;
  /** Shown while the body loads, and instead of it if it cannot be. */
  snippet: string;
  /** Absent when the engine cannot fetch bodies — then the snippet is all there is. */
  readBody?: (id: string) => Promise<MailBody>;
  /** Absent when there is no assistant. Sends the body off the machine when called. */
  summarize?: (id: string) => Promise<{ summary: string; provider: string }>;
}) {
  const [body, setBody] = useState<BodyState>({ status: "loading" });
  const [summary, setSummary] = useState<SummaryState>({ status: "idle" });
  const [open, setOpen] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const textRef = useRef<HTMLParagraphElement>(null);

  // A different message is a fresh start: nothing of the last one's body, summary or
  // expansion may carry over onto it.
  useEffect(() => {
    setSummary({ status: "idle" });
    setOpen(false);
    if (!readBody) {
      setBody({ status: "failed" });
      return;
    }
    let cancelled = false;
    setBody({ status: "loading" });
    readBody(messageId).then(
      (result) => !cancelled && setBody({ status: "ready", body: result }),
      () => !cancelled && setBody({ status: "failed" }),
    );
    return () => {
      cancelled = true;
    };
  }, [messageId, readBody]);

  const text = body.status === "ready" ? body.body.text : null;
  const shown = text ?? snippet;

  // Whether the clamp is hiding anything, measured rather than guessed from a character
  // count: the toggle must never be a button that does nothing.
  useLayoutEffect(() => {
    const el = textRef.current;
    if (!el || open) return;
    setOverflows(el.scrollHeight > el.clientHeight + 1);
  }, [shown, open]);

  async function onSummarize() {
    if (!summarize) return;
    setSummary({ status: "busy" });
    try {
      const result = await summarize(messageId);
      setSummary({ status: "done", text: result.summary, provider: result.provider });
    } catch (failure) {
      setSummary({
        status: "failed",
        message: failure instanceof Error ? failure.message : "The assistant could not be reached.",
      });
    }
  }

  const note =
    body.status === "loading"
      ? "Loading the full email…"
      : body.status === "failed"
        ? "Showing the preview. The full email could not be loaded."
        : body.body.text == null
          ? body.body.unreadable
          : body.body.truncated
            ? "This email is very long, so only the start of it is shown."
            : null;

  return (
    <div className="message">
      <div className="message__bar">
        <span className="field__label">Email</span>
        {summarize && text && (
          <span className="message__summarize">
            <span className="message__hint">Sends this email to your assistant</span>
            <Button
              type="button"
              size="sm"
              variant="default"
              disabled={summary.status === "busy"}
              onClick={() => void onSummarize()}
            >
              {summary.status === "busy" ? "Summarising…" : summary.status === "done" ? "Summarise again" : "Summarise"}
            </Button>
          </span>
        )}
      </div>

      {summary.status === "done" && (
        <div className="message__summary" role="status" aria-label="Summary">
          <p className="message__summary-text">{summary.text}</p>
          <span className="message__provider">Summary by {summary.provider}</span>
        </div>
      )}
      {summary.status === "failed" && (
        <p className="compose__assistnote compose__assistnote--said" role="status">
          {summary.message}
        </p>
      )}

      <p
        ref={textRef}
        className={["message__body", open ? "message__body--open" : ""].filter(Boolean).join(" ")}
        aria-busy={body.status === "loading"}
      >
        {shown}
      </p>

      {(overflows || open) && (
        <button
          type="button"
          className="message__toggle"
          aria-expanded={open}
          onClick={() => setOpen((v) => !v)}
        >
          {open ? "Show less" : "Show whole email"}
        </button>
      )}

      {note && <p className="message__note">{note}</p>}

      {body.status === "ready" && body.body.attachments.length > 0 && (
        <p className="message__note">
          Attachments (not downloaded): {body.body.attachments.join(", ")}
        </p>
      )}
    </div>
  );
}
