/*
 * PrepCard — one coffee chat or interview, before and after.
 *
 * BEFORE it starts, the card is prep: when and where (with the travel buffer the scheduler
 * already uses), the email thread that arranged it, and the tasks he wrote for it. AFTER it
 * ends, and for 48 hours, it flips to follow-through: one optional line about what they talked
 * about, and "Draft thank-you".
 *
 * NOTHING LEAVES ON OPEN. Opening the card reads what the shell already fetched — the week, the
 * triaged inbox, the task lists — and makes no request at all. Summarise and Draft are the only
 * two things that send anything anywhere, both on an explicit press, and both carry an id:
 *
 *  - Summarise → `summarizeMail({ messageId })`. The engine re-reads the body itself.
 *  - Draft thank-you → `draftReply({ messageId, intent: "followUp", instruction })`. The
 *    instruction is built by `thankYouInstruction`, which carries nothing from the calendar.
 *
 * NOTHING SENDS WITHOUT HIM. The draft lands in the one composer the whole app uses, which has
 * its own Review step; this card never calls `sendMail` and has no way to. A drafting failure
 * is not a dead end — it says why and offers the same composer, empty, to write it himself.
 */

import { useState } from "react";
import { api as defaultApi, ApiError, type Draft, type TaskItem } from "../api/client";
import { Button } from "../components/Button";
import { useWriteDesk } from "../compose/WriteDesk";
import type { ComposePrefill } from "../compose/types";
import { presentationFor } from "../lib/category";
import { formatLongDay, formatRange, formatTime } from "../lib/format";
import { replySubject } from "../surfaces/actions";
import {
  endedAgo,
  matchTasks,
  matchThreads,
  MAX_TOPIC,
  prepPhase,
  senderAddress,
  thankYouInstruction,
  thankYouSubject,
  type PrepEvent,
  type PrepPhase,
  type ThreadMatch,
} from "./match";
import { markThanked, usePrepSession } from "./session";
import "./prep.css";

export type PrepClient = Pick<typeof defaultApi, "draftReply" | "summarizeMail">;

interface PrepCardProps {
  prep: PrepEvent;
  drafts: Draft[];
  tasks: TaskItem[];
  /** Read once by the caller when the surface rendered. There is no timer. */
  now: Date;
  /** Injected for tests; the real engine client by default. */
  client?: PrepClient;
  onClose?: () => void;
}

/** In-person needs more turnaround than virtual — the same rule as calendar/scheduling.ts. */
function bufferMinutes(location: string | null): number {
  return location ? 30 : 15;
}

const PHASE_LABEL: Record<PrepPhase, string> = {
  upcoming: "Upcoming",
  live: "Happening now",
  followUp: "Follow-through",
  past: "Earlier",
};

type Summary =
  | { status: "busy" }
  | { status: "done"; text: string; provider: string }
  | { status: "failed"; message: string };

type Drafting = { status: "idle" } | { status: "busy" } | { status: "failed"; message: string };

export function PrepCard({ prep, drafts, tasks, now, client = defaultApi, onClose }: PrepCardProps) {
  const desk = useWriteDesk();
  const capability = desk?.capability;
  const session = usePrepSession();
  const { event } = prep;
  const phase = prepPhase(event, now);
  const threads = matchThreads(prep, drafts);
  const prepTasks = matchTasks(prep, tasks);
  const top: ThreadMatch | undefined = threads[0];
  const thanked = session.thanked.has(event.id);

  const [summaries, setSummaries] = useState<Record<string, Summary>>({});
  const [topic, setTopic] = useState("");
  const [drafting, setDrafting] = useState<Drafting>({ status: "idle" });

  const p = presentationFor(event);
  const after = phase === "followUp" || phase === "past";

  async function summarise(id: string) {
    setSummaries((s) => ({ ...s, [id]: { status: "busy" } }));
    try {
      const result = await client.summarizeMail({ messageId: id });
      setSummaries((s) => ({ ...s, [id]: { status: "done", text: result.summary, provider: result.provider } }));
    } catch (failure) {
      setSummaries((s) => ({
        ...s,
        [id]: {
          status: "failed",
          message: failure instanceof ApiError ? failure.message : "The assistant could not be reached.",
        },
      }));
    }
  }

  /** The composer, pointed at the thread when there is one and at nobody when there is not. */
  function prefillFor(body?: string, provider?: string): ComposePrefill {
    if (!top) {
      // No thread: a blank composer with the subject filled in. He enters the address — the
      // card will not guess one from a calendar event.
      return { to: [], subject: thankYouSubject(prep), ...(body ? { body } : {}), context: prep.label };
    }
    const draft = top.draft;
    return {
      to: [senderAddress(draft.sender!)],
      subject: replySubject(draft.title),
      ...(body ? { body } : {}),
      ...(draft.threadId ? { threadId: draft.threadId } : {}),
      // Kept so "make it shorter" is one press away inside the composer, as for any reply.
      ...(capability?.canDraft && draft.band ? { draftFrom: draft.id } : {}),
      context: provider ? `${draft.sender} · drafted by ${provider}` : draft.sender!,
    };
  }

  function openComposer(prefill: ComposePrefill) {
    desk?.compose(prefill, { onSent: () => markThanked(event.id) });
  }

  // Drafting needs an assistant AND a real inbox message for the engine to re-read. Sample rows
  // have no `band` — nothing engine-side to draft against — so they get the blank path.
  const canDraftThread = Boolean(top && capability?.canDraft && top.draft.band);

  async function draftThankYou() {
    if (!top || !canDraftThread) {
      openComposer(prefillFor());
      return;
    }
    setDrafting({ status: "busy" });
    try {
      const proposal = await client.draftReply({
        messageId: top.draft.id,
        intent: "followUp",
        instruction: thankYouInstruction(event, now, topic),
      });
      setDrafting({ status: "idle" });
      openComposer(prefillFor(proposal.body, proposal.provider));
    } catch (failure) {
      setDrafting({
        status: "failed",
        message: failure instanceof ApiError ? failure.message : "The assistant could not be reached.",
      });
    }
  }

  const leaveBy =
    phase === "upcoming"
      ? formatTime(new Date(new Date(event.start).getTime() - bufferMinutes(event.location) * 60_000).toISOString())
      : null;

  const followThrough = after && (
    <div className={["prep__section", phase === "followUp" ? "prep__section--due" : ""].filter(Boolean).join(" ")}>
      <div className="prep__label">After the event</div>
      {thanked ? (
        <p className="prep__note" role="status">
          Thank-you sent from here this session.
        </p>
      ) : (
        <>
          <p className="prep__lede">
            {phase === "followUp"
              ? `Ended ${endedAgo(event, now)}. A thank-you within a day is the one recruiters notice.`
              : `Ended ${endedAgo(event, now)}. A short note still beats none.`}
          </p>
          {canDraftThread && (
            <>
              <label className="prep__label prep__label--field" htmlFor={`prep-topic-${event.id}`}>
                One thing you talked about <span className="prep__optional">optional</span>
              </label>
              <input
                id={`prep-topic-${event.id}`}
                className="prep__input"
                type="text"
                value={topic}
                maxLength={MAX_TOPIC}
                placeholder="e.g. their move from audit into advisory"
                disabled={drafting.status === "busy"}
                onChange={(e) => setTopic(e.target.value)}
              />
            </>
          )}
          <div className="prep__actions">
            <Button
              variant={phase === "followUp" ? "primary" : "default"}
              size="sm"
              disabled={!desk || drafting.status === "busy"}
              onClick={() => void draftThankYou()}
            >
              {drafting.status === "busy" ? "Drafting…" : canDraftThread ? "Draft thank-you" : "Write thank-you"}
            </Button>
          </div>
          {/* Said before the press, not after: this is the moment something leaves the Mac. */}
          <p className="prep__hint">
            {canDraftThread
              ? "Sends the thread's subject, sender and snippet, plus your line, to the assistant — nothing from your calendar. You review it before anything is emailed."
              : top
                ? "Opens a reply to this thread. Nothing is emailed until you review and send."
                : "No thread to answer, so this opens a blank message — add their address. Nothing is emailed until you review and send."}
          </p>
          {drafting.status === "failed" && (
            <div className="prep__failed" role="alert">
              <span>Couldn't draft it: {drafting.message}</span>
              <Button size="sm" variant="ghost" onClick={() => openComposer(prefillFor())}>
                Write it yourself
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  );

  return (
    <section className="prep" aria-label={`Prep card: ${prep.label}`} style={{ borderColor: p.colorVar }}>
      <header className="prep__head">
        <div>
          <div className="prep__eyebrow">
            {prep.kind} · {PHASE_LABEL[phase]}
          </div>
          <h4 className="prep__title">{event.title}</h4>
        </div>
        {onClose && (
          <Button size="sm" variant="ghost" label="Close prep card" icon={<span aria-hidden="true">×</span>} onClick={onClose} />
        )}
      </header>

      <dl className="prep__facts">
        <dt>When</dt>
        <dd className="num">
          {formatLongDay(event.start)} · {formatRange(event.start, event.end)}
        </dd>
        <dt>Where</dt>
        <dd>{event.location ?? "No location on the event"}</dd>
        {leaveBy && (
          <>
            <dt>Buffer</dt>
            <dd className="num">
              {event.location ? `Leave by ${leaveBy}` : `Be ready by ${leaveBy}`} · {bufferMinutes(event.location)} min
            </dd>
          </>
        )}
      </dl>

      {followThrough}

      <div className="prep__section">
        <div className="prep__label">Related mail</div>
        {threads.length === 0 ? (
          <p className="prep__empty">No thread found for {prep.firms.length ? prep.firms.map((f) => f.label).join(" / ") : "this event"}.</p>
        ) : (
          <ul className="prep__list">
            {threads.map((match) => {
              const summary = summaries[match.draft.id];
              return (
                <li className="prep__thread" key={match.draft.id}>
                  <div className="prep__threadrow">
                    <div className="prep__threadbody">
                      <div className="prep__threadtitle">{match.draft.title}</div>
                      <div className="prep__why">
                        {match.draft.sender} · {match.reason}
                      </div>
                    </div>
                    {capability?.canSummarize && (
                      <Button
                        size="sm"
                        variant="default"
                        disabled={summary?.status === "busy"}
                        title="Sends this email to your assistant"
                        onClick={() => void summarise(match.draft.id)}
                      >
                        {summary?.status === "busy" ? "Summarising…" : summary?.status === "done" ? "Again" : "Summarise"}
                      </Button>
                    )}
                  </div>
                  {summary?.status === "done" && (
                    <div className="prep__summary" role="status" aria-label="Summary">
                      <p>{summary.text}</p>
                      <span className="prep__provider">Summary by {summary.provider}</span>
                    </div>
                  )}
                  {summary?.status === "failed" && (
                    <p className="prep__note" role="status">
                      {summary.message}
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        )}
        {capability?.canSummarize && threads.length > 0 && (
          <p className="prep__hint">Summarise sends that one email to your assistant. Nothing is sent when the card opens.</p>
        )}
      </div>

      <div className="prep__section">
        <div className="prep__label">Prep</div>
        {prepTasks.length === 0 ? (
          <p className="prep__empty">No open tasks mention {prep.firms.length ? prep.firms.map((f) => f.label).join(" / ") : "this event"}.</p>
        ) : (
          <ul className="prep__list">
            {prepTasks.map((task) => (
              <li className="prep__task" key={task.id}>
                <span className="prep__taskbox" aria-hidden="true" />
                <span className="prep__tasktitle">{task.title}</span>
                {phase === "upcoming" && capability?.canSchedule && (
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() => {
                      // An hour, ending where the travel buffer starts, so the prep block and
                      // the walk over do not overlap.
                      const end = new Date(new Date(event.start).getTime() - bufferMinutes(event.location) * 60_000);
                      const start = new Date(end.getTime() - 60 * 60_000);
                      desk?.schedule({
                        title: task.title,
                        start: start.toISOString(),
                        end: end.toISOString(),
                        context: `Prep before ${prep.label} — adds a new block; nothing moves.`,
                      });
                    }}
                  >
                    Block time before
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
