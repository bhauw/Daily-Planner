/*
 * Writing a confirmed plan: N focus blocks, one create at a time, each reported on its own.
 *
 * This is the only code in Plan my day that writes, and it runs only from the confirm button.
 * It goes through the same `createEvent` route the scheduler uses — there is no batch route,
 * and inventing one in the client would be a second write path to keep honest.
 *
 * The rules come from `post()` in api/client.ts, and they are the reason this is a module of
 * its own with its own tests:
 *
 *  - In sequence, not in parallel. Rows update in the order he reads them, and a failure that
 *    means "stop" (see below) is known before the next request leaves.
 *  - No retries, ever, from here. A write whose receipt was unreadable (`bad_response`) may
 *    well have landed; trying again automatically is how a calendar gets two copies of every
 *    block. Such a row is marked ambiguous and he decides — with a warning — whether to retry.
 *  - Partial success is reported per row. "3 of 4 added" with the failing row named is
 *    actionable; one error banner for the batch is not, because he cannot tell which blocks
 *    are now on his calendar.
 *  - Some failures are about the account, not the row: a grant that cannot write, a session
 *    that is no longer authorised, an engine that is gone. Every later row would fail the same
 *    way, so they are not attempted and say so, instead of hammering the engine N times to
 *    collect N copies of the same refusal.
 */

import { ApiError, type ApiErrorCode, type CreateEventRequest, type CreateEventResponse } from "../../api/client";

export type RowState = "waiting" | "creating" | "created" | "failed" | "skipped";

export interface RowResult {
  state: RowState;
  /** Why it failed or was skipped. Display text: the engine's own for write codes. */
  message?: string;
  /** The write may have happened even though it reported failure. */
  ambiguous?: boolean;
  /** The engine's code on a failure, so the batch can tell a row problem from an account one. */
  code?: ApiErrorCode;
  eventId?: string;
  htmlLink?: string | null;
}

export type CreateFn = (request: CreateEventRequest) => Promise<CreateEventResponse>;

/** Failures that say nothing further can succeed in this batch. */
const STOPS: ReadonlySet<ApiErrorCode> = new Set<ApiErrorCode>(["write_not_permitted", "unauthorized", "not_connected"]);

/** One create, turned into a row result. Never throws. */
export async function createOne(request: CreateEventRequest, create: CreateFn): Promise<RowResult> {
  try {
    const receipt = await create(request);
    return { state: "created", eventId: receipt.id, htmlLink: receipt.htmlLink };
  } catch (failure) {
    if (failure instanceof ApiError) {
      const ambiguous = failure.code === "bad_response";
      return {
        state: "failed",
        code: failure.code,
        ambiguous,
        message: ambiguous
          ? "The reply from the engine could not be read, so this may have been added. Check Today before trying again."
          : failure.message,
      };
    }
    return { state: "failed", message: "That could not be added to your calendar." };
  }
}

function stopsBatch(result: RowResult): boolean {
  return result.state === "failed" && result.code != null && STOPS.has(result.code);
}

/**
 * Creates every request in order and returns one result per request.
 *
 * `onChange` fires as each row moves — creating, then its outcome — so the review can show
 * progress row by row rather than a spinner and then a verdict.
 */
export async function createInSequence(
  requests: CreateEventRequest[],
  create: CreateFn,
  onChange?: (index: number, result: RowResult) => void,
): Promise<RowResult[]> {
  const results: RowResult[] = requests.map(() => ({ state: "waiting" }));
  let stopped: string | null = null;

  for (let i = 0; i < requests.length; i++) {
    if (stopped) {
      results[i] = { state: "skipped", message: `Not tried — ${stopped}` };
      onChange?.(i, results[i]);
      continue;
    }
    results[i] = { state: "creating" };
    onChange?.(i, results[i]);

    const result = await createOne(requests[i], create);
    results[i] = result;
    onChange?.(i, result);
    if (stopsBatch(result)) stopped = lowerFirst(result.message ?? "the account refused it.");
  }
  return results;
}

function lowerFirst(text: string): string {
  return text.length === 0 ? text : text[0].toLowerCase() + text.slice(1);
}

/** "3 of 4 added" and friends — the line that tells him what is now on his calendar. */
export function summarise(results: RowResult[]): { created: number; failed: number; skipped: number; text: string } {
  const created = results.filter((r) => r.state === "created").length;
  const failed = results.filter((r) => r.state === "failed").length;
  const skipped = results.filter((r) => r.state === "skipped").length;
  const total = results.length;
  let text: string;
  if (created === total) text = total === 1 ? "Added to your calendar." : `All ${total} added to your calendar.`;
  else if (created === 0) text = total === 1 ? "It was not added." : `None of the ${total} were added.`;
  else text = `${created} of ${total} added.`;
  const notDone = failed + skipped;
  if (notDone > 0 && created > 0) text += ` ${notDone} not added — each is marked below.`;
  return { created, failed, skipped, text };
}
