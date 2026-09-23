/*
 * Plan my day — the morning ritual, as four steps.
 *
 *   1. Read first   — clear the mail that jumped the queue (security, interview, deadline,
 *                     payment), or put it off until later this session.
 *   2. Pick & size  — choose today's tasks and give each an estimate. A meter compares what is
 *                     picked with the free time left in working hours, live.
 *   3. Fit the day  — see where each block would land. Reorder, shrink or drop until it fits.
 *   4. Review & add — the exact events that will be written, then one explicit confirm.
 *
 * NOTHING is written before step 4's button. Steps 1–3 are arithmetic over what is already on
 * screen; the only write is `createInSequence` (./commit.ts), reached from one button. Replying
 * to mail in step 1 goes through the write desk, which has its own confirmation — that is the
 * existing path, not a new one.
 *
 * Why the plan survives a remount: the shell reloads its data after any write, which unmounts
 * the surface. Replying to a must-read in step 1 would otherwise throw away the picks made so
 * far. The plan in progress is kept for this app session only (module state, per day). It is
 * NOT kept across launches, and the UI never says it is.
 *
 * Why the shell reload is deferred until he leaves: reloading unmounts this surface, and the
 * per-row outcome of the write is the one thing he must be able to read afterwards. So the
 * created blocks are picked up when he presses Done, or when he navigates away.
 */

import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { api as defaultApi, type Api, type Capability, type Draft, type PlannerEvent, type Preview, type TasksResponse } from "../../api/client";
import { Button } from "../../components/Button";
import { Dayline } from "../../components/Dayline";
import { EmptyState } from "../../components/Column";
import { colorForCategory } from "../../lib/category";
import { formatLongDay } from "../../lib/format";
import { clock } from "../../workspaces/tasks/insertion";
import { BookIt } from "../../workspaces/mail/BookIt";
import { REASON_LABEL, groupMail } from "../mailTriage";
import { useWriteDesk } from "../../compose/WriteDesk";
import { calendarTemplateURL, replyActions } from "../actions";
import {
  DEFAULT_SIZE,
  SIZES,
  blockTitle,
  candidates as rankCandidates,
  fitPlan,
  formatMinutes,
  freeGaps,
  instantOn,
  planText,
  planningWindow,
  toRequests,
  type Candidate,
  type Fit,
  type Pick,
  type Placed,
} from "./model";
import { createInSequence, createOne, summarise, type RowResult } from "./commit";
import "./plan.css";

export type Step = 1 | 2 | 3 | 4;

const STEP_LABEL: Record<Step, string> = {
  1: "Read first",
  2: "Pick & size",
  3: "Fit the day",
  4: "Review & add",
};

// ---- Session memory ---------------------------------------------------------------------------

interface Session {
  day: string;
  step: Step;
  picks: Pick[];
}

let session: Session | null = null;
/** Mail put off with "Later". Hidden for this app session only, never marked anything upstream. */
const later = new Set<string>();

/** Forget the plan in progress and anything put off. For tests, and after a plan is written. */
export function resetPlanSession(): void {
  session = null;
  later.clear();
}

// ---- The surface --------------------------------------------------------------------------------

interface PlanProps {
  preview: Preview;
  tasks: TasksResponse;
  drafts: Draft[];
  capability: Capability;
  /** The shell's reload. Called once, after something was written, when he is done here. */
  onWrote?: () => void;
  /** Leave the flow for Today. */
  onDone?: () => void;
  /** Injected in tests; the real engine client otherwise. */
  client?: Pick2<Api, "createEvent" | "summarizeMail">;
  /** Injected in tests; the real clock otherwise. */
  now?: Date;
}

// `Pick` is the plan's own noun here, so the utility type needs another name.
type Pick2<T, K extends keyof T> = { [P in K]: T[P] };

export function Plan({ preview, tasks, drafts, capability, onWrote, onDone, client = defaultApi, now }: PlanProps) {
  const day = preview.day;
  const clockNow = useMemo(() => now ?? new Date(), [now]);
  const kept = session && session.day === day ? session : null;

  const [step, setStep] = useState<Step>(kept?.step ?? 1);
  const [picks, setPicks] = useState<Pick[]>(kept?.picks ?? []);
  const [results, setResults] = useState<RowResult[] | null>(null);
  const [running, setRunning] = useState(false);
  const [hidden, setHidden] = useState<Set<string>>(() => new Set(later));

  // Keep the plan in progress for this session; a written plan is finished and is forgotten.
  useEffect(() => {
    session = results ? null : { day, step, picks };
  }, [day, step, picks, results]);

  const hours = useMemo(() => planningWindow(day, clockNow), [day, clockNow]);
  const gaps = useMemo(() => freeGaps(preview.schedule, hours), [preview.schedule, hours]);
  const fit = useMemo(() => fitPlan(picks, gaps), [picks, gaps]);
  const requests = useMemo(() => toRequests(fit.placed, day), [fit.placed, day]);

  const urgent = useMemo(() => groupMail(drafts).urgent.filter((d) => !hidden.has(d.id)), [drafts, hidden]);
  const options = useMemo(() => rankCandidates(tasks.lists, clockNow), [tasks.lists, clockNow]);

  // ---- Reload once, when he leaves, if anything was written ----
  const created = results?.some((r) => r.state === "created") ?? false;
  const reloaded = useRef(false);
  const pendingReload = useRef(false);
  pendingReload.current = created;
  const onWroteRef = useRef(onWrote);
  onWroteRef.current = onWrote;
  useEffect(
    () => () => {
      if (pendingReload.current && !reloaded.current) {
        reloaded.current = true;
        onWroteRef.current?.();
      }
    },
    [],
  );

  function finish() {
    if (created && !reloaded.current) {
      reloaded.current = true;
      onWrote?.();
    }
    onDone?.();
  }

  // ---- Focus follows the step ----
  // Moving to a step moves focus to its heading, so a keyboard or screen-reader user lands on
  // the new content instead of on a Continue button that no longer means what it did. Not on
  // first render: arriving at the page should not yank focus out of the sidebar.
  const headingRef = useRef<HTMLHeadingElement>(null);
  const firstRender = useRef(true);
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    headingRef.current?.focus();
  }, [step]);

  const committed = results != null;

  // ---- Pick editing ----
  function togglePick(c: Candidate) {
    setPicks((prev) =>
      prev.some((p) => p.id === c.id)
        ? prev.filter((p) => p.id !== c.id)
        : [...prev, { id: c.id, title: c.title, minutes: DEFAULT_SIZE, category: c.category, taskId: c.id }],
    );
  }
  const resize = (id: string, minutes: number) =>
    setPicks((prev) => prev.map((p) => (p.id === id ? { ...p, minutes } : p)));
  const drop = (id: string) => setPicks((prev) => prev.filter((p) => p.id !== id));
  function move(id: string, delta: -1 | 1) {
    setPicks((prev) => {
      const i = prev.findIndex((p) => p.id === id);
      const j = i + delta;
      if (i < 0 || j < 0 || j >= prev.length) return prev;
      const next = [...prev];
      [next[i], next[j]] = [next[j], next[i]];
      return next;
    });
  }
  function addCustom(title: string) {
    const id = `custom-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
    setPicks((prev) => [...prev, { id, title, minutes: DEFAULT_SIZE, category: "other", taskId: null }]);
  }
  function putOff(id: string) {
    later.add(id);
    setHidden(new Set(later));
  }

  // ---- The one write ----
  async function confirm() {
    if (running || committed || requests.length === 0) return;
    setRunning(true);
    const snapshot = requests;
    setResults(snapshot.map(() => ({ state: "waiting" })));
    await createInSequence(snapshot, client.createEvent, (i, r) =>
      setResults((prev) => (prev ? prev.map((x, k) => (k === i ? r : x)) : prev)),
    );
    setRunning(false);
    later.clear();
  }

  // A retry is its own explicit press, one row at a time, and never automatic.
  async function retry(index: number) {
    if (running || !results) return;
    setRunning(true);
    setResults((prev) => prev && prev.map((x, k) => (k === index ? { state: "creating" } : x)));
    const r = await createOne(requests[index], client.createEvent);
    setResults((prev) => prev && prev.map((x, k) => (k === index ? r : x)));
    setRunning(false);
  }

  // The day as it will look: what is there, plus the proposal, dashed until it is written.
  const dayEvents = useMemo<PlannerEvent[]>(() => {
    const proposed = fit.placed.flatMap((p, i) => {
      const start = instantOn(day, p.startMin);
      const end = instantOn(day, p.endMin);
      if (!start || !end) return [];
      const state = results?.[i]?.state;
      const written = state === "created";
      // After the write, a block that did not land must not keep reading as a live proposal.
      const suffix = state === "failed" || state === "skipped" ? " · not added" : " · proposed";
      return [
        {
          // The prefix is what plan.css keys the dashed outline on; a written block drops it.
          id: `${written ? "written" : "plan"}-${p.pick.id}`,
          calendarId: "",
          title: written ? blockTitle(p.pick) : `${blockTitle(p.pick)}${suffix}`,
          category: p.pick.category,
          kind: "event" as const,
          start,
          end,
          due: null,
          location: null,
        },
      ];
    });
    return [...preview.schedule, ...proposed];
  }, [fit.placed, preview.schedule, day, results]);

  const canWrite = capability.canSchedule;

  return (
    <div className="plan">
      <div className="plan__main">
        <header className="plan__head">
          <div className="colhead__eyebrow">Plan my day</div>
          <h1 className="plan__title">{formatLongDay(`${day}T12:00:00Z`)}</h1>
          <nav aria-label="Plan steps">
            <ol className="plan__steps">
              {([1, 2, 3, 4] as Step[]).map((n) => (
                <li key={n}>
                  <button
                    type="button"
                    className={["plan__stepbtn", n === step ? "is-on" : "", n < step ? "is-past" : ""]
                      .filter(Boolean)
                      .join(" ")}
                    aria-current={n === step ? "step" : undefined}
                    // Once written, the plan is history: going back to change picks would make
                    // the review disagree with what is now on the calendar.
                    disabled={committed && n !== 4}
                    onClick={() => setStep(n)}
                  >
                    <span className="num plan__stepnum" aria-hidden="true">{n}</span>
                    <span>{n === 4 && !canWrite ? "Review & copy" : STEP_LABEL[n]}</span>
                  </button>
                </li>
              ))}
            </ol>
          </nav>
        </header>

        <section className="plan__body" aria-labelledby="plan-step-title">
          <h2 id="plan-step-title" className="plan__steptitle" tabIndex={-1} ref={headingRef}>
            {stepHeading(step, urgent.length, canWrite)}
          </h2>

          {step === 1 && (
            <ReadFirst drafts={urgent} capability={capability} client={client} onLater={putOff} />
          )}
          {step === 2 && (
            <PickStep options={options} picks={picks} fit={fit} onToggle={togglePick} onResize={resize} onDrop={drop} onAdd={addCustom} />
          )}
          {step === 3 && (
            <FitStep picks={picks} fit={fit} onResize={resize} onDrop={drop} onMove={move} onBack={() => setStep(2)} />
          )}
          {step === 4 && (
            <ReviewStep
              fit={fit}
              day={day}
              canWrite={canWrite}
              results={results}
              running={running}
              onConfirm={() => void confirm()}
              onRetry={(i) => void retry(i)}
              onDone={finish}
              onBack={() => setStep(3)}
            />
          )}
        </section>

        {!committed && (
          <footer className="plan__foot">
            {step > 1 && (
              <Button variant="ghost" onClick={() => setStep((step - 1) as Step)}>
                Back
              </Button>
            )}
            <span className="plan__spacer" />
            {step < 4 && (
              <Button variant="primary" onClick={() => setStep((step + 1) as Step)}>
                {step === 1 ? "Pick today’s work" : step === 2 ? "See how it fits" : "Review the blocks"}
              </Button>
            )}
          </footer>
        )}
      </div>

      <aside className="plan__day" aria-label="Today with the plan">
        <div className="plan__dayhead">
          <div className="colhead__eyebrow">Today</div>
          <FitMeter fit={fit} />
        </div>
        <div className="plan__dayline">
          <Dayline events={dayEvents} />
        </div>
      </aside>
    </div>
  );
}

function stepHeading(step: Step, urgentCount: number, canWrite: boolean): string {
  switch (step) {
    case 1:
      return urgentCount === 0 ? "Nothing to read first" : `Clear ${urgentCount === 1 ? "the one" : `the ${urgentCount}`} that can’t wait`;
    case 2:
      return "What gets time today?";
    case 3:
      return "Where it lands";
    case 4:
      return canWrite ? "Add these to your calendar" : "Your plan, to add yourself";
  }
}

// ---- The meter -------------------------------------------------------------------------------

const LEVEL_WORD: Record<Fit["level"], string> = {
  empty: "Nothing picked",
  full: "Your day is full",
  ok: "Fits",
  tight: "Tight",
  over: "Over",
};

/**
 * Planned time against free time. Length carries the value; the level is also in words, so the
 * state never rests on colour alone (amber past 85%, red once over).
 */
export function FitMeter({ fit }: { fit: Fit }) {
  const pct = fit.freeMin === 0 ? (fit.plannedMin > 0 ? 100 : 0) : Math.min(100, Math.round(fit.ratio * 100));
  const text =
    fit.level === "full"
      ? `No free time left in working hours`
      : `${formatMinutes(fit.plannedMin)} planned / ${formatMinutes(fit.freeMin)} free`;
  const tail = fit.level === "over" ? ` · over by ${formatMinutes(fit.overByMin)}` : "";
  return (
    <div className={`fitmeter fitmeter--${fit.level}`}>
      <div className="fitmeter__row">
        <span className="fitmeter__word">{LEVEL_WORD[fit.level]}</span>
        <span className="num fitmeter__text">
          {text}
          {tail}
        </span>
      </div>
      <span
        className="fitmeter__track"
        role="meter"
        aria-label="Planned time against free time"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={pct}
        aria-valuetext={`${LEVEL_WORD[fit.level]}: ${text}${tail}`}
      >
        <span className="fitmeter__fill" style={{ width: `${pct}%` }} />
      </span>
    </div>
  );
}

// ---- Step 1 --------------------------------------------------------------------------------------

type SummaryState = { status: "idle" } | { status: "busy" } | { status: "done"; text: string; provider: string } | { status: "error"; text: string };

function ReadFirst({
  drafts,
  capability,
  client,
  onLater,
}: {
  drafts: Draft[];
  capability: Capability;
  client: Pick2<Api, "summarizeMail">;
  onLater: (id: string) => void;
}) {
  if (drafts.length === 0) {
    return (
      <EmptyState
        title="Inbox can wait"
        detail="No security alerts, interviews, deadlines or payments are waiting. Go on to picking today’s work."
      />
    );
  }
  return (
    <>
      <p className="plan__lede">
        These jumped the queue. Deal with each now, or put it off — “Later” only hides it here, for this
        session.
      </p>
      <ul className="mustreads">
        {drafts.map((d) => (
          <MustRead key={d.id} draft={d} capability={capability} client={client} onLater={onLater} />
        ))}
      </ul>
    </>
  );
}

function MustRead({
  draft,
  capability,
  client,
  onLater,
}: {
  draft: Draft;
  capability: Capability;
  client: Pick2<Api, "summarizeMail">;
  onLater: (id: string) => void;
}) {
  const [summary, setSummary] = useState<SummaryState>({ status: "idle" });
  const badge = draft.reason ? REASON_LABEL[draft.reason] : "";
  // Only the reply itself: the row's other actions live on Digest, and five buttons per message
  // is a triage screen, not a morning checklist. Built by `replyActions`, so it is the same
  // reply every other surface offers — the in-app composer with a send grant, Gmail without.
  const desk = useWriteDesk();
  const reply = replyActions(draft, capability).find((a) => a.id === "reply");
  function openReply() {
    if (!reply) return;
    if (reply.compose && desk) desk.compose(reply.compose);
    else if (reply.href) window.open(reply.href, "_blank", "noopener,noreferrer");
  }
  // Summarising sends the body to the assistant, so it is offered only when the engine says it
  // can, and only for a message the engine triaged (sample rows have nothing to re-read).
  const canSummarize = capability.canSummarize && draft.band != null;

  async function summarize() {
    setSummary({ status: "busy" });
    try {
      const r = await client.summarizeMail({ messageId: draft.id });
      setSummary({ status: "done", text: r.summary, provider: r.provider });
    } catch (e) {
      setSummary({ status: "error", text: e instanceof Error ? e.message : "That could not be summarised." });
    }
  }

  const shown = summary.status === "done" ? summary.text : draft.summary;

  return (
    <li className="mustread" style={{ ["--mr-accent" as string]: colorForCategory(draft.category ?? "other") }}>
      <div className="mustread__top">
        {badge && <span className="mustread__badge">{badge}</span>}
        <span className="mustread__title">{draft.title}</span>
      </div>
      <div className="mustread__meta">
        {draft.sender ?? "Unknown sender"}
        {draft.why ? ` · ${draft.why}` : ""}
      </div>
      {shown && <p className="mustread__summary">{shown}</p>}
      {summary.status === "done" && <p className="mustread__provider">Summary by {summary.provider}</p>}
      {summary.status === "error" && (
        <p className="mustread__error" role="alert">
          {summary.text}
        </p>
      )}
      <BookIt text={shown ?? ""} subject={draft.title} receivedAt={draft.receivedAt} accepted={false} />
      <div className="mustread__actions" role="group" aria-label={`Actions for ${draft.title}`}>
        {reply && (
          <Button size="sm" variant="primary" onClick={openReply} aria-label={`${reply.label}: ${draft.title}`}>
            {reply.label}
          </Button>
        )}
        {canSummarize && summary.status !== "done" && (
          <Button size="sm" onClick={() => void summarize()} disabled={summary.status === "busy"} aria-label={`Summarise: ${draft.title}`}>
            {summary.status === "busy" ? "Summarising…" : "Summarise"}
          </Button>
        )}
        <Button size="sm" variant="ghost" onClick={() => onLater(draft.id)} aria-label={`Later: ${draft.title}`}>
          Later
        </Button>
      </div>
    </li>
  );
}

// ---- Step 2 --------------------------------------------------------------------------------------

function SizeChips({ pick, onResize, label }: { pick: Pick; onResize: (id: string, m: number) => void; label: string }) {
  return (
    <div className="sizes" role="group" aria-label={`Estimate for ${label}`}>
      {SIZES.map((m) => (
        <button
          key={m}
          type="button"
          className={`sizes__chip num${pick.minutes === m ? " is-on" : ""}`}
          aria-pressed={pick.minutes === m}
          onClick={() => onResize(pick.id, m)}
        >
          {m < 60 ? `${m}m` : `${m / 60 === 1 ? "1h" : "1h 30m"}`}
        </button>
      ))}
    </div>
  );
}

function PickStep({
  options,
  picks,
  fit,
  onToggle,
  onResize,
  onDrop,
  onAdd,
}: {
  options: Candidate[];
  picks: Pick[];
  fit: Fit;
  onToggle: (c: Candidate) => void;
  onResize: (id: string, m: number) => void;
  onDrop: (id: string) => void;
  onAdd: (title: string) => void;
}) {
  const pinned = options.filter((o) => o.pinned);
  const rest = options.filter((o) => !o.pinned);
  const custom = picks.filter((p) => p.taskId == null);
  const byId = new Map(picks.map((p) => [p.id, p]));

  const row = (c: Candidate) => {
    const pick = byId.get(c.id);
    return (
      <li key={c.id} className={`pickrow${pick ? " is-picked" : ""}`}>
        <label className="pickrow__label">
          <input type="checkbox" className="pickrow__check" checked={pick != null} onChange={() => onToggle(c)} />
          <span className="pickrow__chip" style={{ background: colorForCategory(c.category) }} aria-hidden="true" />
          <span className="pickrow__body">
            <span className="pickrow__title">{c.title}</span>
            <span className="pickrow__meta">
              {c.list}
              {c.due ? ` · ${c.reason}` : ""}
            </span>
          </span>
        </label>
        {pick && <SizeChips pick={pick} onResize={onResize} label={c.title} />}
      </li>
    );
  };

  return (
    <>
      {fit.level === "full" ? (
        <p className="plan__callout plan__callout--over" role="status">
          Your day is full — there is no stretch of {15} minutes or more left between 09:00 and 21:00. Anything
          you pick here will not fit; see step 3 for what to drop.
        </p>
      ) : (
        <p className="plan__lede">
          Tick what gets time today and size each one. Sizes last for this plan only.
        </p>
      )}

      {options.length === 0 && custom.length === 0 && (
        <EmptyState
          title="Nothing to plan"
          detail="No open tasks are waiting. Add a block below for anything you want protected time for."
        />
      )}

      {pinned.length > 0 && (
        <PickGroup title="Due today or earlier" count={pinned.length}>
          {pinned.map(row)}
        </PickGroup>
      )}
      {rest.length > 0 && (
        <PickGroup title={pinned.length > 0 ? "Everything else open" : "Open tasks"} count={rest.length}>
          {rest.map(row)}
        </PickGroup>
      )}

      {custom.length > 0 && (
        <PickGroup title="Added by you" count={custom.length}>
          {custom.map((p) => (
            <li key={p.id} className="pickrow is-picked">
              <span className="pickrow__label">
                <span className="pickrow__chip" style={{ background: colorForCategory(p.category) }} aria-hidden="true" />
                <span className="pickrow__body">
                  <span className="pickrow__title">{p.title}</span>
                </span>
              </span>
              <SizeChips pick={p} onResize={onResize} label={p.title} />
              <Button size="sm" variant="ghost" onClick={() => onDrop(p.id)} aria-label={`Remove ${p.title}`}>
                Remove
              </Button>
            </li>
          ))}
        </PickGroup>
      )}

      <AddBlock onAdd={onAdd} />
    </>
  );
}

function PickGroup({ title, count, children }: { title: string; count: number; children: ReactNode }) {
  return (
    <section className="pickgroup" aria-label={title}>
      <div className="pickgroup__head">
        <span className="colhead__eyebrow">{title}</span>
        <span className="num pickgroup__count">{count}</span>
      </div>
      <ul className="pickgroup__list">{children}</ul>
    </section>
  );
}

function AddBlock({ onAdd }: { onAdd: (title: string) => void }) {
  const [text, setText] = useState("");
  return (
    <form
      className="addblock"
      onSubmit={(e) => {
        e.preventDefault();
        const t = text.trim();
        if (!t) return;
        onAdd(t);
        setText("");
      }}
    >
      <label className="addblock__field">
        <span className="addblock__label">Add a block</span>
        <input
          className="addblock__input"
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Something that isn’t a task yet"
          autoComplete="off"
        />
      </label>
      <Button type="submit" size="sm" disabled={text.trim().length === 0}>
        Add
      </Button>
    </form>
  );
}

// ---- Step 3 --------------------------------------------------------------------------------------

function FitStep({
  picks,
  fit,
  onResize,
  onDrop,
  onMove,
  onBack,
}: {
  picks: Pick[];
  fit: Fit;
  onResize: (id: string, m: number) => void;
  onDrop: (id: string) => void;
  onMove: (id: string, d: -1 | 1) => void;
  onBack: () => void;
}) {
  if (picks.length === 0) {
    return (
      <EmptyState
        title="Nothing picked yet"
        detail="Pick at least one task, or add a block, and it is placed into your free time here."
        action={<Button size="sm" onClick={onBack}>Pick today’s work</Button>}
      />
    );
  }

  const placedBy = new Map(fit.placed.map((p) => [p.pick.id, p]));
  const overflowIds = new Set(fit.overflow.map((p) => p.id));

  return (
    <>
      <FitCallout fit={fit} />
      <p className="plan__lede">
        In your order: the first gets the earliest free stretch it fits in. Classes and anything already on
        the calendar are never moved.
      </p>
      <ol className="fitlist">
        {picks.map((p, i) => {
          const placed = placedBy.get(p.id);
          const over = overflowIds.has(p.id);
          return (
            <li key={p.id} className={`fitrow${over ? " is-over" : ""}`}>
              <span className="num fitrow__rank" aria-hidden="true">{i + 1}</span>
              <span className="fitrow__body">
                <span className="fitrow__title">{p.title}</span>
                <span className={`num fitrow__when${over ? " is-over" : ""}`}>
                  {placed ? `${clock(placed.startMin)}–${clock(placed.endMin)}` : "Doesn’t fit"}
                </span>
              </span>
              <SizeChips pick={p} onResize={onResize} label={p.title} />
              <span className="fitrow__order">
                <Button size="sm" variant="ghost" disabled={i === 0} onClick={() => onMove(p.id, -1)} aria-label={`Move ${p.title} earlier`}>
                  ↑
                </Button>
                <Button size="sm" variant="ghost" disabled={i === picks.length - 1} onClick={() => onMove(p.id, 1)} aria-label={`Move ${p.title} later`}>
                  ↓
                </Button>
                <Button size="sm" variant="ghost" onClick={() => onDrop(p.id)} aria-label={`Drop ${p.title}`}>
                  Drop
                </Button>
              </span>
            </li>
          );
        })}
      </ol>
    </>
  );
}

function FitCallout({ fit }: { fit: Fit }) {
  if (fit.level === "full") {
    return (
      <p className="plan__callout plan__callout--over" role="status">
        Your day is full. There is no free stretch left in working hours, so nothing here can be placed.
      </p>
    );
  }
  if (fit.overflow.length > 0) {
    const n = fit.overflow.length;
    const why =
      fit.level === "over"
        ? `You have picked ${formatMinutes(fit.plannedMin)} for ${formatMinutes(fit.freeMin)} of free time — over by ${formatMinutes(fit.overByMin)}.`
        : `The total fits, but no single free stretch is long enough for ${n === 1 ? "it" : "them"}.`;
    return (
      <p className="plan__callout plan__callout--over" role="status">
        {n === 1 ? "1 block doesn’t fit." : `${n} blocks don’t fit.`} {why} Shrink or drop something — only
        what fits is added.
      </p>
    );
  }
  if (fit.level === "tight") {
    return (
      <p className="plan__callout plan__callout--tight" role="status">
        It fits, with {formatMinutes(fit.freeMin - fit.plannedMin)} to spare. That leaves little room for
        anything that runs long.
      </p>
    );
  }
  return (
    <p className="plan__callout" role="status">
      It fits, with {formatMinutes(fit.freeMin - fit.plannedMin)} still free.
    </p>
  );
}

// ---- Step 4 --------------------------------------------------------------------------------------

const ROW_WORD: Record<RowResult["state"], string> = {
  waiting: "Waiting",
  creating: "Adding…",
  created: "Added",
  failed: "Not added",
  skipped: "Not tried",
};

function ReviewStep({
  fit,
  day,
  canWrite,
  results,
  running,
  onConfirm,
  onRetry,
  onDone,
  onBack,
}: {
  fit: Fit;
  day: string;
  canWrite: boolean;
  results: RowResult[] | null;
  running: boolean;
  onConfirm: () => void;
  onRetry: (i: number) => void;
  onDone: () => void;
  onBack: () => void;
}) {
  const [copied, setCopied] = useState(false);
  const outcomeRef = useRef<HTMLParagraphElement>(null);
  const finished = results != null && !running;
  // When the batch settles, the outcome is the thing to read next — take focus there.
  useEffect(() => {
    if (finished) outcomeRef.current?.focus();
  }, [finished]);

  if (fit.placed.length === 0) {
    return (
      <EmptyState
        title="Nothing to add yet"
        detail={
          fit.overflow.length > 0
            ? "None of the picked blocks fit today. Shrink or drop something in step 3."
            : "Pick something in step 2 and it is placed and listed here."
        }
        action={<Button size="sm" onClick={onBack}>Back to the fit</Button>}
      />
    );
  }

  const n = fit.placed.length;
  const outcome = results && finished ? summarise(results) : null;

  async function copy() {
    try {
      await navigator.clipboard.writeText(planText(fit.placed, day));
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // A denied clipboard is not worth a dialog; the plan is on screen to read.
    }
  }

  return (
    <>
      {!canWrite ? (
        <p className="plan__callout plan__callout--tight">
          This account is connected for reading only, so the app can’t put these on your calendar. Copy the
          plan, or open each one in Google Calendar and save it there.
        </p>
      ) : results == null ? (
        <p className="plan__lede">
          {n === 1 ? "This event is" : `These ${n} events are`} added to your primary calendar exactly as listed.
          Nothing has been written yet.
          {fit.overflow.length > 0 &&
            ` ${fit.overflow.length === 1 ? "1 block that doesn’t fit is" : `${fit.overflow.length} blocks that don’t fit are`} left out.`}
        </p>
      ) : null}

      {outcome && (
        <p
          ref={outcomeRef}
          tabIndex={-1}
          className={`plan__callout${outcome.created === results!.length ? "" : " plan__callout--over"}`}
          role="status"
        >
          {outcome.text}
        </p>
      )}

      <ul className="review" aria-label="Focus blocks to add">
        {fit.placed.map((p: Placed, i) => {
          const r = results?.[i];
          const start = instantOn(day, p.startMin);
          const end = instantOn(day, p.endMin);
          const gcal =
            !canWrite && start && end
              ? calendarTemplateURL({ title: blockTitle(p.pick), start: new Date(start), end: new Date(end) })
              : undefined;
          return (
            <li key={p.pick.id} className={`reviewrow${r ? ` is-${r.state}` : ""}`}>
              <span className="num reviewrow__time">
                {clock(p.startMin)}–{clock(p.endMin)}
              </span>
              <span className="reviewrow__body">
                <span className="reviewrow__title">{blockTitle(p.pick)}</span>
                <span className="num reviewrow__meta">{formatMinutes(p.endMin - p.startMin)}</span>
                {r?.message && <span className="reviewrow__why">{r.message}</span>}
              </span>
              {r && (
                <span className={`reviewrow__state is-${r.state}`} aria-live="polite">
                  {ROW_WORD[r.state]}
                </span>
              )}
              {r?.state === "failed" && !running && (
                <Button size="sm" onClick={() => onRetry(i)} aria-label={`Try again: ${blockTitle(p.pick)}`}>
                  {r.ambiguous ? "Try again anyway" : "Try again"}
                </Button>
              )}
              {gcal && (
                <Button size="sm" onClick={() => window.open(gcal, "_blank", "noopener,noreferrer")} aria-label={`Open in Calendar: ${blockTitle(p.pick)}`}>
                  Open in Calendar
                </Button>
              )}
            </li>
          );
        })}
      </ul>

      <div className="plan__confirm">
        {!canWrite ? (
          <Button variant="primary" onClick={() => void copy()}>
            {copied ? "Copied" : "Copy plan"}
          </Button>
        ) : results == null ? (
          <>
            <Button variant="primary" onClick={onConfirm} disabled={running}>
              {n === 1 ? "Add 1 focus block" : `Add ${n} focus blocks`}
            </Button>
            <span className="plan__confirmnote">One press adds them all. You can move or delete any of them later.</span>
          </>
        ) : (
          <Button variant="primary" onClick={onDone} disabled={running}>
            {running ? "Adding…" : "Done — back to Today"}
          </Button>
        )}
      </div>
    </>
  );
}
