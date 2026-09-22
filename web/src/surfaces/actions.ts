/*
 * What you can do with a thing, once you have pressed it.
 *
 * Digest and Focus list events, replies and tasks. Pressing a row should answer
 * "and what do I do about it" without a second screen, so each row opens onto
 * the actions that fit *that kind of item* — reschedule an event, reply to a
 * message, put a task on the day.
 *
 * Shape of the decision, from the research:
 *
 *  - Actions are ALWAYS VISIBLE once a row is open, never hover-only. NN/g's
 *    finding on row actions is blunt about this: hover-revealed controls are
 *    measurably harder to discover, and on a trackpad they are easy to lose.
 *  - Every action carries a text label. An icon-only button with no name is an
 *    accessibility anti-pattern and a guessing game.
 *  - Sending mail is IRREVERSIBLE, so it is the one thing that gets a
 *    confirmation step rather than a bare button. Reversible things get done
 *    immediately with an undo affordance instead: confirming everything trains
 *    people to click through the one dialog that mattered.
 *  - Single-key shortcuts follow the verbs people already know from mail
 *    clients: R reply, S schedule, E done, O open.
 *
 * This module is pure data — no React, no fetch — so the action set for any
 * item is testable on its own, which is where the rules above actually live.
 */

import type { Draft, PlannerEvent, TaskItem } from "../api/client";
import type { ComposePrefill, SchedulePrefill } from "../compose/types";

/** What invoking an action does. The surface decides how to carry it out. */
export type ActionEffect =
  /** Open an external page in the browser. Read-only, always safe. */
  | "open"
  /** Put text on the clipboard. Read-only, always safe. */
  | "copy"
  /** Open the composer for a reply. Sending is a separate, confirmed step. */
  | "compose"
  /** Open the scheduler to put this on the calendar. */
  | "schedule";

export interface ItemAction {
  id: string;
  label: string;
  effect: ActionEffect;
  /** The accent action for this item. At most one per item. */
  primary?: boolean;
  /** Target for `open`, and the fallback for `compose`/`schedule` with no write grant. */
  href?: string;
  /** Payload for `copy`. */
  text?: string;
  /** Single-key shortcut while the row has focus. */
  shortcut?: string;
  /**
   * What the in-app composer opens with. Present only when the grant can send — a row with
   * this goes to the write desk; a row with only `href` goes to Gmail.
   */
  compose?: ComposePrefill;
  /** The same, for the in-app scheduler. */
  schedule?: SchedulePrefill;
  /**
   * Set when the action is real but cannot run yet, with the reason shown to
   * the user. Better than hiding it (the capability is coming and the row
   * should say so) and far better than a button that silently does nothing.
   */
  unavailable?: string;
}

/** Whether the engine can currently perform writes. Drives `unavailable`. */
export interface ActionCapability {
  canSend: boolean;
  canSchedule: boolean;
  /** Whether an event already on the calendar can be moved, rather than copied. */
  canReschedule?: boolean;
  /** Whether an assistant is available to propose a reply body. */
  canDraft?: boolean;
}

export const NO_WRITES: ActionCapability = {
  canSend: false,
  canSchedule: false,
  canReschedule: false,
  canDraft: false,
};

/**
 * Google's own compose and event-creation screens, prefilled.
 *
 * These are now the FALLBACK, not the path. With send and schedule granted, a
 * row opens the app's own composer and the message goes out from here. These
 * remain for the read-only case — an account connected before write scopes
 * existed can still act on every row, it just finishes the job in Google.
 *
 * Labelled "in Gmail" / "in Calendar" when that is where they go, on purpose.
 * A button that says "Reply" and then throws you into another tab is a small
 * betrayal; one that says where it is taking you is just a link.
 */
function gmailComposeURL(options: { to?: string; subject: string; body?: string }): string {
  const params = new URLSearchParams({ view: "cm", fs: "1", su: options.subject });
  if (options.to) params.set("to", options.to);
  if (options.body) params.set("body", options.body);
  return `https://mail.google.com/mail/u/0/?${params.toString()}`;
}

/** Google Calendar's TEMPLATE screen wants UTC basic-format timestamps. */
function calendarStamp(date: Date): string {
  return `${date.toISOString().replace(/[-:]/g, "").split(".")[0]}Z`;
}

/**
 * Undefined rather than a throw when a date cannot be read.
 *
 * `Date.toISOString()` raises `RangeError` on an invalid date, and this runs
 * during render — so one unparseable timestamp from the provider would take
 * out the entire surface, not just its own row. That is the same failure shape
 * as the calendar page that used to fail wholesale on a single bad event.
 */
export function calendarTemplateURL(options: {
  title: string;
  start: Date;
  end: Date;
  details?: string;
  location?: string;
}): string | undefined {
  if (Number.isNaN(options.start.getTime()) || Number.isNaN(options.end.getTime())) {
    return undefined;
  }
  const params = new URLSearchParams({
    action: "TEMPLATE",
    text: options.title,
    dates: `${calendarStamp(options.start)}/${calendarStamp(options.end)}`,
  });
  if (options.details) params.set("details", options.details);
  if (options.location) params.set("location", options.location);
  return `https://calendar.google.com/calendar/render?${params.toString()}`;
}

/** A reply subject, without stacking "Re:" every time. */
export function replySubject(subject: string): string {
  return /^re:/i.test(subject.trim()) ? subject.trim() : `Re: ${subject.trim()}`;
}

/** Default block for a task put on the day: the next hour, on the hour. */
export function defaultBlock(now: Date, minutes = 60): { start: Date; end: Date } {
  const start = new Date(now);
  start.setMinutes(0, 0, 0);
  start.setHours(start.getHours() + 1);
  return { start, end: new Date(start.getTime() + minutes * 60_000) };
}

/** Google's day view for the date an event sits on. No event id needed. */
export function calendarDayURL(iso: string): string | undefined {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return undefined;
  // Google reads this path in the viewer's own locale/zone, which is the
  // machine the user is sitting at — the same place this app is running.
  return `https://calendar.google.com/calendar/u/0/r/day/${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
}

/**
 * A Gmail search for the message, by subject.
 *
 * The engine's draft contract carries no message or thread id — see
 * `PlannerEventDTO` missing `calendarID` for the same shape of gap — so a
 * direct deep link is not possible yet. A subject search lands on the thread
 * in one click, which is worth more than no action at all, and this becomes a
 * real permalink the moment the id is on the wire.
 */
export function gmailSearchURL(subject: string): string {
  return `https://mail.google.com/mail/u/0/#search/${encodeURIComponent(subject)}`;
}

const TASKS_URL = "https://tasks.google.com/";

export function eventActions(event: PlannerEvent, capability: ActionCapability): ItemAction[] {
  const when = [event.start, event.end].filter(Boolean).join(" – ");
  const details = [event.title, when, event.location].filter(Boolean).join("\n");
  const day = calendarDayURL(event.start);

  const reschedule = calendarTemplateURL({
    title: event.title,
    start: new Date(event.start),
    end: new Date(event.end ?? event.start),
    location: event.location ?? undefined,
  });


  /*
   * "Move it" now moves.
   *
   * It used to INSERT a second event with the same details and leave the original where it
   * was — on the user's real calendar — because no update route existed. It does that only as
   * a fallback now: when the engine reports `canReschedule` and the event names the calendar
   * it is on, the action carries a move target and the desk patches the event in place.
   *
   * The fallback is kept rather than hidden, and it says what it does. An account connected to
   * an older engine, or an event read without a calendar, still gets a usable action — the
   * label just stops claiming to move something.
   */
  const start = new Date(event.start);
  const timesKnown = !Number.isNaN(start.getTime());
  const end = event.end ?? new Date(start.getTime() + 60 * 60_000).toISOString();
  const canMove = capability.canReschedule === true && Boolean(event.calendarId) && Boolean(event.id);

  const inApp: SchedulePrefill | undefined =
    capability.canSchedule && timesKnown
      ? {
          title: event.title,
          start: event.start,
          end,
          ...(event.location ? { location: event.location } : {}),
          ...(canMove
            ? {
                context: `Moving ${event.title}. This changes the event you already have.`,
                move: { eventId: event.id, calendarId: event.calendarId },
              }
            : {
                context: `${event.title} — this adds a NEW block; the original stays where it is.`,
              }),
        }
      : undefined;

  return [
    ...(inApp
      ? [
          {
            id: "reschedule",
            // Only the real move is called "Move it". The fallback inserts a block and says so,
            // because a button that says move and then duplicates is the bug this route fixed.
            label: canMove ? "Move it" : "Add a block instead",
            effect: "schedule" as const,
            primary: true,
            shortcut: "s",
            schedule: inApp,
          },
        ]
      : reschedule
      ? [
          {
            id: "reschedule",
            label: "Reschedule in Calendar",
            effect: "schedule" as const,
            primary: true,
            shortcut: "s",
            href: reschedule,
          },
        ]
      : []),
    ...(day
      ? [{ id: "open-calendar", label: "Open in Calendar", effect: "open" as const, href: day, shortcut: "o" }]
      : []),
    { id: "copy-event", label: "Copy details", effect: "copy", text: details },
  ];
}

export function replyActions(draft: Draft, capability: ActionCapability): ItemAction[] {
  // A reply needs somewhere to go. Without a sender there is no address to answer, so the row
  // offers to find the thread instead of opening a composer with an empty To field.
  const canReplyInApp = capability.canSend && Boolean(draft.sender);

  return [
    {
      id: "reply",
      label: canReplyInApp ? "Reply" : "Reply in Gmail",
      effect: "compose",
      primary: true,
      shortcut: "r",
      ...(canReplyInApp
        ? {
            compose: {
              to: [draft.sender!],
              subject: replySubject(draft.title),
              // The thread id is what makes this land in the conversation it answers rather
              // than beside it. Absent on sample data, which has no real thread.
              ...(draft.threadId ? { threadId: draft.threadId } : {}),
              // The id the assistant would draft against. Carried only when an assistant
              // exists, so the composer shows the offer exactly when it can honour it. Sample
              // rows have no engine-side message to re-read, so they never get it.
              ...(capability.canDraft && draft.band ? { draftFrom: draft.id } : {}),
              context: draft.sender!,
            } satisfies ComposePrefill,
          }
        : {
            href: gmailComposeURL({
              to: draft.sender,
              subject: replySubject(draft.title),
            }),
          }),
    },
    {
      id: "open-gmail",
      label: "Find in Gmail",
      effect: "open",
      href: gmailSearchURL(draft.title),
      shortcut: "o",
    },
    ...(draft.sender
      ? [{ id: "copy-sender", label: "Copy address", effect: "copy" as const, text: draft.sender }]
      : []),
  ];
}

export function taskActions(task: TaskItem, capability: ActionCapability): ItemAction[] {
  const due = task.due ? new Date(task.due) : new Date();
  const block = defaultBlock(Number.isNaN(due.getTime()) ? new Date() : due);

  return [
    {
      id: "schedule-task",
      label: capability.canSchedule ? "Put on the day" : "Block time in Calendar",
      effect: "schedule",
      primary: true,
      shortcut: "s",
      ...(capability.canSchedule
        ? {
            schedule: {
              title: task.title,
              start: block.start.toISOString(),
              end: block.end.toISOString(),
              context: "Blocking time for this task",
            } satisfies SchedulePrefill,
          }
        : {
            href: calendarTemplateURL({ title: task.title, start: block.start, end: block.end }),
          }),
    },
    { id: "open-tasks", label: "Open in Tasks", effect: "open", href: TASKS_URL, shortcut: "o" },
    { id: "copy-task", label: "Copy title", effect: "copy", text: task.title },
  ];
}

/** True when the action changes something outside this app. */
export function isExternalWrite(action: ItemAction): boolean {
  return action.effect === "compose" || action.effect === "schedule";
}
