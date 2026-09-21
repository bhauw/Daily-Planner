/*
 * QuickCapture — one input, reachable by keyboard from anywhere in the workspace
 * (press "c" while not typing), that proposes a routed task. On submit it never
 * creates anything: it shows the suggested list, the suggested due DATE, an
 * explicit follow-on question (does this also need calendar time or an email?),
 * and — crucially — *why* it routed the way it did, so every assumption the
 * product makes is visible. The person approves or rejects; approval is local.
 */

import { useEffect, useRef, useState } from "react";
import { Button } from "../contract";
import type { CaptureProposal } from "./machine";
import { statusLabel } from "./machine";
import { formatDueDate } from "./routing";
import { PlusIcon } from "./icons";

interface QuickCaptureProps {
  captures: CaptureProposal[];
  onCapture: (text: string) => void;
  onResolve: (id: string, status: "approved" | "rejected") => void;
  onDismiss: (id: string) => void;
}

export function QuickCapture({ captures, onCapture, onResolve, onDismiss }: QuickCaptureProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [text, setText] = useState("");
  // Local-only follow-up answers layered over each proposal's suggestion.
  const [followups, setFollowups] = useState<Record<string, { calendar: boolean; email: boolean }>>({});

  // Keyboard shortcut: "c" focuses the capture input from anywhere in the
  // workspace, unless the person is already typing in a field.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key !== "c" || e.metaKey || e.ctrlKey || e.altKey) return;
      const el = e.target as HTMLElement | null;
      const typing = el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable);
      if (typing) return;
      e.preventDefault();
      inputRef.current?.focus();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  function submit() {
    const trimmed = text.trim();
    if (!trimmed) return;
    onCapture(trimmed);
    setText("");
  }

  function followupFor(c: CaptureProposal) {
    return followups[c.id] ?? { calendar: c.needsCalendar, email: c.needsEmail };
  }

  function setFollowup(id: string, patch: Partial<{ calendar: boolean; email: boolean }>) {
    setFollowups((prev) => ({ ...prev, [id]: { ...(prev[id] ?? { calendar: false, email: false }), ...patch } }));
  }

  const pending = captures.filter((c) => c.status === "pending");
  const resolved = captures.filter((c) => c.status !== "pending");

  return (
    <section className="capture" aria-label="Quick capture">
      <form
        className="capture__bar"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label className="capture__field">
          <span className="sr-only">Capture a task</span>
          <input
            ref={inputRef}
            className="capture__input"
            type="text"
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="Capture a task — e.g. “email Example Consulting recruiter tomorrow”"
            aria-describedby="capture-hint"
          />
        </label>
        <Button type="submit" variant="primary" icon={<PlusIcon />} disabled={!text.trim()}>
          Route it
        </Button>
      </form>
      <p id="capture-hint" className="capture__hint">
        Press <kbd className="num">C</kbd> to capture from anywhere. Capture proposes — it never creates.
      </p>

      {pending.length > 0 && (
        <div className="capture__proposals">
          {pending.map((c) => {
            const f = followupFor(c);
            const due = formatDueDate(c.due);
            return (
              <article className="proposal" key={c.id} aria-label={`Proposed task: ${c.text}`}>
                <div className="proposal__head">
                  <div className="proposal__title">{c.text}</div>
                  <span className="proposal__status is-pending">{statusLabel(c.status)}</span>
                </div>

                <dl className="proposal__facts">
                  <div className="proposal__fact">
                    <dt>List</dt>
                    <dd>{c.listName}</dd>
                  </div>
                  <div className="proposal__fact">
                    <dt>Due</dt>
                    <dd className="num">{due ?? "No due date"}</dd>
                  </div>
                </dl>

                <div className="proposal__why">
                  <div className="proposal__why-head">Why it routed this way</div>
                  <ul className="proposal__reasons">
                    {c.reasons.map((r, i) => (
                      <li key={i}>{r}</li>
                    ))}
                  </ul>
                </div>

                <fieldset className="proposal__followup">
                  <legend>Does it also need…</legend>
                  <label className="check">
                    <input
                      type="checkbox"
                      checked={f.calendar}
                      onChange={(e) => setFollowup(c.id, { calendar: e.target.checked })}
                    />
                    <span>Calendar time (a focus block)</span>
                  </label>
                  <label className="check">
                    <input
                      type="checkbox"
                      checked={f.email}
                      onChange={(e) => setFollowup(c.id, { email: e.target.checked })}
                    />
                    <span>An email</span>
                  </label>
                </fieldset>

                <div className="proposal__actions">
                  <Button size="sm" variant="primary" onClick={() => onResolve(c.id, "approved")}>
                    Approve
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => onResolve(c.id, "rejected")}>
                    Discard
                  </Button>
                  <span className="proposal__note">Approving keeps it local — nothing is sent this round.</span>
                </div>
              </article>
            );
          })}
        </div>
      )}

      {resolved.length > 0 && (
        <ul className="capture__log" aria-label="Resolved captures">
          {resolved.map((c) => (
            <li className="capture__log-row" key={c.id}>
              <span className={`proposal__status is-${c.status}`}>{statusLabel(c.status)}</span>
              <span className="capture__log-text">{c.text}</span>
              <button type="button" className="capture__log-dismiss" onClick={() => onDismiss(c.id)}>
                <span className="sr-only">Dismiss {c.text}</span>
                <span aria-hidden="true">×</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
