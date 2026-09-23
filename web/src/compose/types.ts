/*
 * What a row hands to the write desk when you press Reply or Schedule.
 *
 * Pure data, carried on the action itself, so `actions.ts` stays what its
 * header promises — data with no React and no fetch — and the prefill for any
 * row is testable without rendering anything.
 */

import type { PlannerEvent, ReplyIntent } from "../api/client";

/**
 * The intent a TYPED instruction goes out on.
 *
 * The client's intents are a closed set with no "custom", and adding one would change the wire
 * contract. It does not need one: the engine puts a typed instruction IN PLACE OF the intent's own
 * wording (`customInstruction ?? intent.instruction`, ReplyDraftingPorts.swift), so the intent
 * is only a label on the request. Both drafting surfaces sent "accept" as that label, so "politely
 * decline" went out tagged as a yes. `acknowledge` is the one intent that commits to nothing
 * ("Do not commit to anything"), so even an engine that fell back to the intent could never turn
 * his no into a yes.
 */
export const FREE_FORM_INTENT: ReplyIntent = "acknowledge";

export interface ComposePrefill {
  to: string[];
  cc?: string[];
  subject: string;
  body?: string;
  /** The Gmail thread this reply belongs to, when there is one. */
  threadId?: string;
  /** The Message-ID being answered, so the reply threads rather than starting anew. */
  inReplyTo?: string;
  /** Shown above the form so it is obvious what is being replied to. */
  context?: string;
  /**
   * The inbox message this is answering, when an assistant could draft against it.
   *
   * An ID only. The engine re-reads the message and builds the prompt from its own copy, so
   * the rule that a private message is never transmitted holds against the provider's
   * classification rather than against anything this client passes along.
   */
  draftFrom?: string;
  /**
   * The inbox item this answers, by its draft id. Handed back on a successful send so the shell
   * can drop that item from every list at once, rather than leaving an answered message sitting
   * there as if nothing happened. Client-side only; never sent.
   */
  answers?: string;
}

/** What a successful write did, so the host can reflect it before the re-read lands. */
export type Written =
  | { kind: "mail"; answers?: string }
  | { kind: "event" };

/**
 * Naming an event that already exists, so the desk MOVES it instead of creating one.
 *
 * Its presence is what switches the scheduler from "add" to "move": absent, the form creates a
 * new event exactly as before. Both ids come from a read — the client never invents either.
 */
export interface MoveTarget {
  eventId: string;
  calendarId: string;
}

export interface SchedulePrefill {
  title: string;
  /** ISO instants. The form renders them as local wall-clock values. */
  start: string;
  end: string;
  location?: string;
  description?: string;
  context?: string;
  /**
   * Set to move the named event rather than create a new one.
   *
   * When it is present the form shows the title as text and drops Where and Notes, because the
   * move route cannot change them — an editable field whose edits are discarded is worse than
   * no field at all.
   */
  move?: MoveTarget;
  /**
   * What is already on the calendar around this time, so the form can name an overlap before
   * it is pressed. Read-side context only — it is never sent.
   */
  busy?: PlannerEvent[];
}
