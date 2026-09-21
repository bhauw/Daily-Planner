/*
 * Typed client for the loopback engine API.
 *
 * The Swift host binds 127.0.0.1 on a random high port and injects a per-launch
 * bearer token as `window.__DP_TOKEN__` before this bundle runs. Every request
 * carries `Authorization: Bearer <token>`. If the token is absent we are not
 * connected to the engine — we surface that state and never retry in a loop.
 *
 * Error contract (matches BRIEF.md): a failed request throws an ApiError whose
 * `code` is a finite enum string and whose `message` is safe display text. We
 * never log provider content, tokens, file paths, or the excluded-calendar
 * identity — only finite codes.
 */

declare global {
  interface Window {
    __DP_TOKEN__?: string;
  }
}

// ---- Domain types (the API contract every workspace builds against) ----

/*
 * Must match `APICategory` in APIContract.swift exactly — asserted against the engine's own
 * generated contract in api/contract.test.ts. `commute` and `work` are NOT decorative: the
 * engine keeps them separate because a commute block means scheduling must not add its own
 * travel buffer on top, and work is a hard conflict like a class. Folding them into `other`
 * here silently discarded that.
 */
export const CATEGORIES = [
  "school",
  "career",
  "finance",
  "personal",
  "other",
  "commute",
  "work",
] as const;
export type Category = (typeof CATEGORIES)[number];
export type EventKind = "event" | "deadline" | "extracurricular" | "advertisement";

export interface PlannerEvent {
  id: string;
  title: string;
  category: Category;
  kind: EventKind;
  start: string; // ISO8601 with offset
  end: string | null;
  due: string | null;
  location: string | null;
}

export interface Preview {
  queue: PlannerEvent[];
  schedule: PlannerEvent[];
  day: string; // "2026-09-14"
}

export type CalendarRole = "planning" | "excluded";

export interface CalendarSummary {
  id: string;
  title: string;
  role: CalendarRole;
}

/**
 * The next seven days, today included. `/api/preview` is deliberately one day; the digest needs
 * to say what is coming, and a day read alone is not a plan.
 */
export interface WeekResponse {
  /** First day covered, "YYYY-MM-DD" — today. */
  start: string;
  /** How many days the window covers, today included. */
  days: number;
  /** Every eligible event in the window, in start order. Today's included. */
  events: PlannerEvent[];
}

export interface CalendarsResponse {
  calendars: CalendarSummary[];
}

/**
 * The engine's safety descriptor. This was typed `Record<string, boolean>`, but the engine
 * sends `mode` and `label` as strings — so both were typed as booleans, and the dev mock sent
 * a third shape again (`{externalWrites, network}`, no `mode`/`label`). Nothing rendered wrong
 * only because SafetyRail hardcodes its wording. Same seam as the leg-2 drifts; the contract
 * test now pins every field.
 */
/**
 * What the engine may currently do to the outside world.
 *
 * `mode` was "read-only" and nothing else while the engine had no write routes, and the rail
 * below hardcoded that wording. Both had to change together the moment the first write route
 * shipped: a safety label that is reassuring rather than accurate is worse than none, because it
 * is the line the user reads to know what this app can do with their account.
 */
export type SafetyMode = "read-only" | "send-and-schedule";

export interface Safety {
  mode: SafetyMode | string;
  externalWrites: boolean;
  label: string;
}

/**
 * What the connected grant permits, straight from the engine.
 *
 * The client used to guess at this (`NO_WRITES`, hardcoded), so a row could offer "Reply"
 * against a token that cannot send, or hide it against one that can. Both are the same bug: the
 * button and the grant disagreeing.
 */
export interface Capability {
  canSend: boolean;
  canSchedule: boolean;
}

/** Which data the engine is serving. `sample` means the Keychain read failed or no account is connected. */
export type SourceKind = "connected" | "sample";

export interface Source {
  kind: SourceKind;
  /** True only for the user's real account. Warn off this, not off `kind`. */
  live: boolean;
  label: string;
}

export interface Settings {
  vaultSelected: boolean;
  scanTimes: string[];
  safety: Safety;
  source: Source;
  capability: Capability;
}

// ---- Write requests ----

export interface SendMailRequest {
  to: string[];
  cc?: string[];
  bcc?: string[];
  subject: string;
  body: string;
  /** The Gmail thread this reply belongs to, when composing from a mail row. */
  threadId?: string;
  /** The RFC 2822 Message-ID being answered, so the reply threads properly. */
  inReplyTo?: string;
}

export interface SendMailResponse {
  ok: boolean;
  id: string;
  threadId: string | null;
}

export interface CreateEventRequest {
  calendarId?: string;
  title: string;
  /** ISO8601 with an offset, as the rest of this contract uses. */
  start: string;
  end: string;
  location?: string;
  description?: string;
}

export interface CreateEventResponse {
  ok: boolean;
  id: string;
  start: string;
  end: string;
  htmlLink: string | null;
}

export type DraftKind = "reply" | "bundle" | "event" | "task";

export interface Draft {
  id: string;
  title: string;
  summary: string;
  kind: DraftKind;
  /** Present on real inbox items (triage). Absent on synthetic/generated drafts. */
  sender?: string;
  category?: Category;
  receivedAt?: string | null;
  /**
   * The Gmail thread this belongs to. Handed straight back on a reply so it lands in the
   * conversation it answers instead of starting a new one beside it. Null on sample data.
   */
  threadId?: string | null;
}

export interface DraftsResponse {
  drafts: Draft[];
}

export interface TaskItem {
  id: string;
  title: string;
  category: Category;
  due: string | null;
  done: boolean;
}

export interface TaskList {
  name: string;
  items: TaskItem[];
}

export interface TasksResponse {
  lists: TaskList[];
}

export interface Health {
  ok: boolean;
  mode: string;
}

// ---- Error shape ----

export type ApiErrorCode =
  | "not_connected"
  | "unauthorized"
  | "network"
  | "bad_response"
  | "server_error"
  // Write-path codes. Unlike the read codes, these arrive with display text the engine wrote
  // for this exact failure ("Check the recipient address."), and that text is what the user
  // needs — so `post` keeps it instead of substituting a generic sentence.
  | "invalid_request"
  | "write_not_permitted"
  | "provider_refused"
  | "too_large";

export class ApiError extends Error {
  readonly code: ApiErrorCode;
  constructor(code: ApiErrorCode, message: string) {
    super(message);
    this.name = "ApiError";
    this.code = code;
  }
}

const SAFE_MESSAGE: Record<ApiErrorCode, string> = {
  not_connected: "Not connected to the engine.",
  unauthorized: "This session is not authorized to read the engine.",
  network: "The engine could not be reached.",
  bad_response: "The engine returned an unexpected response.",
  server_error: "The engine reported an error.",
  invalid_request: "That could not be sent as written.",
  write_not_permitted: "This account is connected for reading only.",
  provider_refused: "Google would not accept that.",
  too_large: "That is too large to send.",
};

/** The write codes the engine can return, so an unknown one is not trusted as display text. */
const WRITE_CODES = new Set<string>([
  "invalid_request",
  "write_not_permitted",
  "provider_refused",
  "too_large",
]);

export function token(): string | undefined {
  return typeof window !== "undefined" ? window.__DP_TOKEN__ : undefined;
}

export function isConnected(): boolean {
  return typeof token() === "string" && token()!.length > 0;
}

async function get<T>(path: string): Promise<T> {
  const t = token();
  if (!t) throw new ApiError("not_connected", SAFE_MESSAGE.not_connected);

  let res: Response;
  try {
    res = await fetch(path, {
      method: "GET",
      headers: { Authorization: `Bearer ${t}`, Accept: "application/json" },
    });
  } catch {
    // Never include the underlying error — it can leak URLs/hosts.
    throw new ApiError("network", SAFE_MESSAGE.network);
  }

  if (res.status === 401) throw new ApiError("unauthorized", SAFE_MESSAGE.unauthorized);
  if (res.status >= 500) throw new ApiError("server_error", SAFE_MESSAGE.server_error);
  if (!res.ok) throw new ApiError("bad_response", SAFE_MESSAGE.bad_response);

  try {
    return (await res.json()) as T;
  } catch {
    throw new ApiError("bad_response", SAFE_MESSAGE.bad_response);
  }
}

/**
 * A write. Three things make this different from `get`, and all three are deliberate:
 *
 *  - It never retries, and nothing above it may. A send that may or may not have happened must
 *    not be attempted a second time on the user's behalf — a duplicate email is worse than an
 *    unclear one.
 *  - It surfaces the engine's own message. Those strings are finite, written for this failure,
 *    and carry none of what the user typed; "Check the recipient address." is worth more than
 *    "The engine reported an error."
 *  - The browser attaches `Origin` automatically, and the engine requires it. That is what makes
 *    a cross-site POST fail even if the token ever leaked into a page.
 */
async function post<TRequest, TResponse>(path: string, payload: TRequest): Promise<TResponse> {
  const t = token();
  if (!t) throw new ApiError("not_connected", SAFE_MESSAGE.not_connected);

  let res: Response;
  try {
    res = await fetch(path, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${t}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch {
    throw new ApiError("network", SAFE_MESSAGE.network);
  }

  if (res.ok) {
    try {
      return (await res.json()) as TResponse;
    } catch {
      // The write may well have succeeded and only the receipt was unreadable, so this is not
      // reported as a refusal — and it is emphatically not retried.
      throw new ApiError("bad_response", SAFE_MESSAGE.bad_response);
    }
  }

  if (res.status === 401) throw new ApiError("unauthorized", SAFE_MESSAGE.unauthorized);

  let code: ApiErrorCode = res.status >= 500 ? "server_error" : "bad_response";
  let message = SAFE_MESSAGE[code];
  try {
    const body = (await res.json()) as { error?: { code?: string; message?: string } };
    const engineCode = body.error?.code;
    if (engineCode && WRITE_CODES.has(engineCode)) {
      code = engineCode as ApiErrorCode;
      message = body.error?.message || SAFE_MESSAGE[code];
    } else if (engineCode === "unavailable") {
      code = "server_error";
      message = body.error?.message || SAFE_MESSAGE.server_error;
    }
  } catch {
    // Keep the status-derived code; an unparseable error body is not worth a second failure.
  }
  throw new ApiError(code, message);
}

export const api = {
  health: () => get<Health>("/api/health"),
  preview: () => get<Preview>("/api/preview"),
  week: () => get<WeekResponse>("/api/week"),
  calendars: () => get<CalendarsResponse>("/api/calendars"),
  settings: () => get<Settings>("/api/settings"),
  drafts: () => get<DraftsResponse>("/api/drafts"),
  tasks: () => get<TasksResponse>("/api/tasks"),
  sendMail: (request: SendMailRequest) =>
    post<SendMailRequest, SendMailResponse>("/api/mail/send", request),
  createEvent: (request: CreateEventRequest) =>
    post<CreateEventRequest, CreateEventResponse>("/api/calendar/events", request),
};

export type Api = typeof api;
