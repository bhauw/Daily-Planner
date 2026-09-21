/*
 * What a row hands to the write desk when you press Reply or Schedule.
 *
 * Pure data, carried on the action itself, so `actions.ts` stays what its
 * header promises — data with no React and no fetch — and the prefill for any
 * row is testable without rendering anything.
 */

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
}

export interface SchedulePrefill {
  title: string;
  /** ISO instants. The form renders them as local wall-clock values. */
  start: string;
  end: string;
  location?: string;
  description?: string;
  context?: string;
}
