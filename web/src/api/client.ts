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
  /**
   * The calendar this event is on.
   *
   * Required to move it: an event is patched on the calendar it lives on, and `primary` is a
   * guess that touches the wrong event or none. The engine carried this in its domain all
   * along and dropped it at the DTO, which is why "Move it" could only ever insert a copy.
   */
  calendarId: string;
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
  /**
   * Whether an event the user already has can be MOVED, rather than a new one created.
   *
   * Asked separately from `canSchedule` because it depends on the engine having a move route,
   * not only on what Google granted. An older engine answers `undefined` here, which is falsy,
   * so the client falls back to the honest prefill-a-new-block behaviour rather than sending a
   * move to a route that does not exist.
   */
  canReschedule: boolean;
  /**
   * Whether an assistant is available to propose replies. Independent of the Google grant —
   * it depends on a CLI or a local model being on the machine, not on what the account allows.
   */
  canDraft: boolean;
  /** Whether a message's full body can be fetched to read. Local only; nothing leaves. */
  canReadBody: boolean;
  /**
   * Whether a body can be summarised. Needs a body AND an assistant, and unlike reading it sends
   * the body off this Mac — which is why the two are reported apart.
   */
  canSummarize: boolean;
}

/**
 * The assistant, and where your content goes when you use it.
 *
 * Separate from `Safety` on purpose: `safety.mode` says what this app may do TO your account,
 * this says where your content GOES. They are different promises and the rail states both.
 */
export interface Assist {
  enabled: boolean;
  /** "Claude (your subscription)", "Local model", … Empty when nothing is wired. */
  provider: string;
  /** True when drafting transmits the message off this Mac. */
  contentLeavesMachine: boolean;
  label: string;
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
  /** Absent on an engine built before drafting shipped; the client then shows no assistant. */
  assist?: Assist;
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

/**
 * Moving an event the user already has: an identity, a calendar, and two times.
 *
 * There is deliberately no title or description here. This request cannot rename or
 * re-describe anything, because those fields do not exist on it to send.
 */
export interface MoveEventRequest {
  eventId: string;
  calendarId: string;
  start: string;
  end: string;
}

/** What the user wants a proposed reply to do. A closed set, mirroring the engine's. */
export type ReplyIntent =
  | "accept"
  | "decline"
  | "reschedule"
  | "acknowledge"
  | "askQuestion"
  | "followUp";

/**
 * Asking for a proposed reply.
 *
 * Carries an ID, never the message text. The engine re-reads the message and builds the prompt
 * from its own copy, so the rule that a private message is never transmitted holds against the
 * provider's classification rather than against anything the client claims.
 */
export interface DraftReplyRequest {
  messageId: string;
  intent: ReplyIntent;
  /**
   * What the user typed instead of pressing an intent button.
   *
   * The only free text this route accepts, and it is an instruction ABOUT the message — never
   * the message. The engine still re-reads the mail from its own copy, so this cannot be used
   * to smuggle content in.
   */
  instruction?: string;
}

/**
 * One message's body, for the Mail workbench to show.
 *
 * DISPLAY ONLY. Drafting never reads it: `DraftReplyRequest` still carries an id, and the engine
 * still builds the draft prompt from the snippet. Seeing more does not mean sending more.
 */
export interface MailBody {
  id: string;
  /** Null when the body could not be read safely; `unreadable` says why. */
  text: string | null;
  truncated: boolean;
  attachments: string[];
  unreadable: string | null;
}

/** An id and nothing else — the engine re-reads the body itself, so none can be supplied. */
export interface SummarizeMailRequest {
  messageId: string;
}

export interface SummarizeMailResponse {
  ok: boolean;
  summary: string;
  provider: string;
}

export interface DraftReplyResponse {
  ok: boolean;
  /** The proposed body. Opens in the composer for editing; nothing is sent from here. */
  body: string;
  provider: string;
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
  /**
   * Which triage band the engine put this in. Absent on synthetic content, which is not
   * ranked — the client treats absent as "not triaged" and renders the row plainly rather
   * than inventing a band for it.
   */
  band?: MailBand;
  reason?: MailReason;
  /** Why it is ranked where it is, in the user's words. Shown on the row. */
  why?: string;
  /** Still unread at the provider. */
  unread?: boolean;
}

/** Urgent overrides category order; ordinary sits in its category's place. */
export type MailBand = "urgent" | "ordinary";

/** The four overrides, plus the ordinary case. */
export type MailReason = "security" | "interview" | "deadline" | "obligation" | "category";

export interface DraftsResponse {
  drafts: Draft[];
  /**
   * Promotions, social and spam the engine withheld. Shown as a count so hiding them stays
   * honest — a silently shorter list is worse than a stated one.
   */
  hiddenCount?: number;
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
  /** Moves an existing event. A POST here; the engine sends Google a PATCH. */
  moveEvent: (request: MoveEventRequest) =>
    post<MoveEventRequest, CreateEventResponse>("/api/calendar/events/move", request),
  /** One message's body, to read. Local: the engine sends it nowhere. */
  mailBody: (id: string) => get<MailBody>(`/api/mail/body?id=${encodeURIComponent(id)}`),
  /** Summarises one message. Sends its body to the assistant — only ever on request. */
  summarizeMail: (request: SummarizeMailRequest) =>
    post<SummarizeMailRequest, SummarizeMailResponse>("/api/mail/summary", request),
  /** Asks for a proposed reply. Sends nothing and changes nothing in the account. */
  draftReply: (request: DraftReplyRequest) =>
    post<DraftReplyRequest, DraftReplyResponse>("/api/mail/draft", request),
};

export type Api = typeof api;
