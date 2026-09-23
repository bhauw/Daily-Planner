/*
 * Prep → follow-through: the pure half.
 *
 * A coffee chat or an interview is three things the app already sees apart — the calendar
 * event, the email thread that arranged it, and the prep tasks he wrote for it — and one thing
 * it does not see at all: the thank-you note recruiters expect within a day. This module links
 * the first three and decides when the fourth is due. No React, no fetch, no clock of its own:
 * every function takes `now`, so the 48-hour window is tested at its edges rather than trusted.
 *
 * WHY A FRONT-END MATCHER. The engine hands the web everything needed — the week's events,
 * the triaged inbox (subject + sender), the task lists — and linking them is a judgement about
 * words, not a query. Keeping it here keeps it out of the DTOs the contract test pins, and
 * keeps it where the reason for every match can be shown next to the match.
 *
 * WHY DOMAIN-BOUNDED. A sender "matches Example Consulting" when its address is at the configured employer domain or a subdomain of
 * it — never when an employer name merely appears somewhere in it. `recruiting@example.test` and
 * `example.test.example.com` are exactly the shapes a phishing sender takes, and a card that files
 * one under "the thread that arranged your Example Consulting chat" hands it the trust of a real one. Same
 * rule as TriageProfile.matchesHost in the engine, for the same reason.
 *
 * WHY WORD-BOUNDED. "EY" is two letters. A substring test finds it in "hey", "key", "survey"
 * and "Money", so every token is matched on word boundaries, never with `includes`.
 */

import type { Draft, PlannerEvent, TaskItem } from "../api/client";

// ---- Firms ------------------------------------------------------------------------------

export interface Firm {
  id: string;
  /** How the firm writes its own name — used in reasons and on the card. */
  label: string;
  /** Lower-case phrases that name the firm in a title or subject, matched on word boundaries. */
  words: string[];
  /** Hosts the firm mails from. A sender matches the host itself or any subdomain of it. */
  hosts: string[];
}

/**
 * The firms a Sauder student recruiting for accounting and advisory co-ops actually meets.
 *
 * The Big Four first, then the national mid-tier and the banks that recruit the same cohort.
 * A firm not on this list still links: `eventTokens` falls back to the distinctive words of
 * the event title, so "Coffee chat — Acme Advisory" can find a thread from acme.com.
 */
export const FIRMS: readonly Firm[] = [
  { id: "example-corp", label: "Example Corp", words: ["example corp"], hosts: ["example.test"] },
  { id: "pwc", label: "PwC", words: ["pwc", "pricewaterhousecoopers"], hosts: ["pwc.com", "pwc.ca"] },
  { id: "ey", label: "EY", words: ["ey", "ernst & young", "ernst and young"], hosts: ["ey.com"] },
  { id: "example-consulting", label: "Example Consulting", words: ["example consulting"], hosts: ["example.test"] },
  { id: "grant-thornton", label: "Grant Thornton", words: ["grant thornton"], hosts: ["doanegrantthornton.ca", "grantthornton.ca", "grantthornton.com"] },
  { id: "bdo", label: "BDO", words: ["bdo"], hosts: ["bdo.ca", "bdo.com"] },
  { id: "mnp", label: "MNP", words: ["mnp"], hosts: ["mnp.ca"] },
  { id: "rsm", label: "RSM", words: ["rsm"], hosts: ["rsmcanada.com", "rsmus.com"] },
  { id: "baker-tilly", label: "Baker Tilly", words: ["baker tilly"], hosts: ["bakertilly.ca", "bakertilly.com"] },
  { id: "crowe", label: "Crowe", words: ["crowe", "crowe mackay"], hosts: ["crowemackay.ca", "crowe.com"] },
  { id: "accenture", label: "Accenture", words: ["accenture"], hosts: ["accenture.com"] },
  { id: "rbc", label: "RBC", words: ["rbc", "royal bank"], hosts: ["rbc.com"] },
  { id: "bmo", label: "BMO", words: ["bmo"], hosts: ["bmo.com"] },
  { id: "scotiabank", label: "Scotiabank", words: ["scotiabank", "scotia"], hosts: ["scotiabank.com"] },
  { id: "cibc", label: "CIBC", words: ["cibc"], hosts: ["cibc.com", "cibc.ca"] },
  { id: "td", label: "TD", words: ["td bank", "td securities"], hosts: ["td.com", "tdsecurities.com"] },
];

// ---- Text helpers -----------------------------------------------------------------------

/**
 * Lower-cased, with every run of punctuation turned into one space and padded at both ends.
 *
 * `&` survives because "Ernst & Young" is spelled with it. Padding means a word test is one
 * `includes(" word ")` — the spaces ARE the boundaries.
 */
export function normalize(text: string): string {
  const folded = text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "");
  return ` ${folded.replace(/[^a-z0-9&]+/g, " ").trim()} `;
}

/** Whether a phrase appears in already-normalized text on word boundaries. */
function hasPhrase(normalized: string, phrase: string): boolean {
  const needle = normalize(phrase);
  return needle.trim().length > 0 && normalized.includes(needle);
}

/**
 * The address part of a sender, lower-cased: "Jordan Lee <jordan@example.test>" → "jordan@example.test".
 * The engine sends a bare address today; a display-name form costs nothing to accept.
 */
export function senderAddress(sender: string): string {
  const angle = /<([^>]+)>/.exec(sender);
  return (angle ? angle[1] : sender).trim().toLowerCase();
}

/** The host a sender mails from, or "" when the address has none. */
export function senderHost(sender: string): string {
  const address = senderAddress(sender);
  const at = address.lastIndexOf("@");
  return at < 0 ? "" : address.slice(at + 1);
}

/**
 * Whether a sender's host IS `host` or a subdomain of it.
 *
 * "example.test" matches "jordan@example.test" and "hr@mail.example.test", and matches neither
 * "x@notexample.test" (no dot boundary) nor "x@example.test.example.com" (the host does not END there).
 */
export function hostMatches(sender: string, host: string): boolean {
  const from = senderHost(sender);
  const wanted = host.trim().toLowerCase();
  if (!from || !wanted) return false;
  return from === wanted || from.endsWith(`.${wanted}`);
}

// ---- Detection --------------------------------------------------------------------------

export type PrepKind = "interview" | "coffee chat" | "networking";

/**
 * The phrases that make an event a conversation someone should prepare for and thank people
 * after. Order matters: "Interview" beats "chat" when a title says both.
 */
const KIND_PHRASES: { kind: PrepKind; phrases: string[] }[] = [
  {
    kind: "interview",
    phrases: ["interview", "phone screen", "final round", "superday", "assessment centre", "assessment center"],
  },
  { kind: "coffee chat", phrases: ["coffee chat", "coffee", "chat", "informational", "info chat"] },
  {
    kind: "networking",
    phrases: ["networking", "info session", "information session", "office tour", "meet and greet", "mixer"],
  },
];

/**
 * Words that describe the meeting, the role or the logistics rather than naming who it is with.
 * Stripped before a title's leftover words are used as a firm token, so "Coffee chat — Audit
 * senior" does not go looking for every email that says "audit".
 */
const GENERIC_WORDS = new Set([
  "coffee", "chat", "interview", "phone", "screen", "final", "round", "first", "second", "third",
  "call", "meeting", "meet", "greet", "with", "and", "the", "for", "virtual", "zoom", "teams",
  "office", "tour", "info", "information", "session", "networking", "mixer", "prep", "audit",
  "assurance", "advisory", "consulting", "tax", "coop", "co", "op", "intern", "internship",
  "recruiter", "recruiting", "partner", "manager", "senior", "associate", "analyst", "campus",
  "event", "superday", "assessment", "centre", "center", "informational", "reschedule", "ask",
  "hold", "confirmed", "tentative", "new", "time", "follow", "thank", "you", "vancouver",
]);

/** A firm token that is not a known firm: the distinctive words left in the title. */
const MIN_GENERIC_TOKEN = 4;

export interface PrepEvent {
  event: PlannerEvent;
  kind: PrepKind;
  /** Known firms named in the title. Usually one. */
  firms: Firm[];
  /**
   * Lower-case words to match threads and tasks by when no known firm is named. Empty when a
   * known firm is, because the firm's own words and hosts are the better evidence.
   */
  tokens: string[];
  /** "Example Consulting coffee chat" — how the card and the thank-you row name it. */
  label: string;
}

export function firmsIn(text: string): Firm[] {
  const hay = normalize(text);
  return FIRMS.filter((firm) => firm.words.some((w) => hasPhrase(hay, w)));
}

function kindOf(title: string): PrepKind | null {
  const hay = normalize(title);
  for (const { kind, phrases } of KIND_PHRASES) {
    if (phrases.some((p) => hasPhrase(hay, p))) return kind;
  }
  return null;
}

/** The distinctive leftover words of a title, for firms the list above does not know. */
export function eventTokens(title: string): string[] {
  const words = normalize(title).trim().split(" ");
  const seen = new Set<string>();
  for (const word of words) {
    if (word.length < MIN_GENERIC_TOKEN || /^\d+$/.test(word) || GENERIC_WORDS.has(word)) continue;
    seen.add(word);
  }
  return [...seen];
}

/**
 * Whether an event is a chat or an interview worth a prep card, and what it is with.
 *
 * CAREER is assigned upstream from the event's Google colour (Banana → career, in
 * GoogleColorModels.swift), so category alone is a colour the user picked — it says "this is
 * recruiting", not "this is a conversation". The rule is therefore:
 *
 *  - only `kind: "event"` — a deadline has nobody to thank, and an extracurricular is a club;
 *  - a career-coloured event qualifies when its title names the conversation or a firm;
 *  - an uncoloured one still qualifies when it names BOTH ("Interview — Example Corp" left grey),
 *    because a forgotten colour should not cost him the thank-you;
 *  - "Coffee with Sam" in personal magenta names no firm and stays a personal coffee.
 */
export function detectPrep(event: PlannerEvent): PrepEvent | null {
  if (event.kind !== "event") return null;
  if (Number.isNaN(new Date(event.start).getTime())) return null;

  const kind = kindOf(event.title);
  const firms = firmsIn(event.title);
  const career = event.category === "career";

  const qualifies = career ? kind != null || firms.length > 0 : kind != null && kind !== "networking" && firms.length > 0;
  if (!qualifies) return null;

  const resolvedKind: PrepKind = kind ?? "coffee chat";
  const tokens = firms.length > 0 ? [] : eventTokens(event.title);
  const who = firms.length > 0 ? firms.map((f) => f.label).join(" / ") : "";
  const label = who ? `${who} ${resolvedKind}` : event.title;
  return { event, kind: resolvedKind, firms, tokens, label };
}

// ---- Thread matching --------------------------------------------------------------------

export interface ThreadMatch {
  draft: Draft;
  /** "matched “Example Consulting” in subject" / "sender is @example.test" — shown beside the match, always. */
  reason: string;
  score: number;
}

/** Up to three, as the card shows. More than that is a search result, not a link. */
export const MAX_THREADS = 3;

/**
 * The email threads that plausibly arranged this event, strongest first, each with its reason.
 *
 * Only real inbox rows are candidates — they carry a `sender`. A synthetic proposal ("Calendar
 * + Task bundle") has nobody to reply to, so it can never be the thread a thank-you answers.
 *
 * A sender at the firm's host outranks a subject that merely names the firm: a newsletter can
 * say "Example Consulting", only Example Consulting can mail from example.test. Both together outrank either.
 */
export function matchThreads(prep: PrepEvent, drafts: Draft[], limit = MAX_THREADS): ThreadMatch[] {
  const matches: ThreadMatch[] = [];

  drafts.forEach((draft, index) => {
    if (!draft.sender) return;
    const subject = normalize(draft.title);
    const reasons: string[] = [];
    let score = 0;

    for (const firm of prep.firms) {
      const host = firm.hosts.find((h) => hostMatches(draft.sender!, h));
      if (host) {
        reasons.push(`sender is @${senderHost(draft.sender)}`);
        score += 2;
      }
      const word = firm.words.find((w) => hasPhrase(subject, w));
      if (word) {
        reasons.push(`matched “${firm.label}” in subject`);
        score += 1;
      }
    }

    for (const token of prep.tokens) {
      // The host's LABELS, not its text: "acme" is a label of mail.acme.com and is not one of
      // notacme.com. Same boundary rule as `hostMatches`, applied to a word we only guessed.
      const labels = senderHost(draft.sender).split(".");
      if (labels.slice(0, -1).includes(token)) {
        reasons.push(`sender is @${senderHost(draft.sender)}`);
        score += 2;
      }
      if (hasPhrase(subject, token)) {
        reasons.push(`matched “${token}” in subject`);
        score += 1;
      }
    }

    if (score > 0) {
      // De-duplicated: two firm hosts can yield the same "sender is" line.
      const reason = [...new Set(reasons)].join(" · ");
      matches.push({ draft, reason, score: score * 1000 - index });
    }
  });

  return matches.sort((a, b) => b.score - a.score).slice(0, limit);
}

/** Open tasks that share the event's firm token — "Prep Example Corp STAR stories". */
export function matchTasks(prep: PrepEvent, tasks: TaskItem[]): TaskItem[] {
  const words = [...prep.firms.flatMap((f) => f.words), ...prep.tokens];
  if (words.length === 0) return [];
  return tasks.filter((task) => {
    if (task.done) return false;
    const title = normalize(task.title);
    return words.some((w) => hasPhrase(title, w));
  });
}

// ---- Time: the 48-hour window -----------------------------------------------------------

/** How long after an event ends the card offers the thank-you, and Today reminds him. */
export const FOLLOW_UP_WINDOW_MS = 48 * 60 * 60 * 1000;
/** An event with no end is treated as this long — the default coffee chat, as in scheduling.ts. */
const DEFAULT_LENGTH_MS = 45 * 60 * 1000;

export type PrepPhase =
  /** Before it starts: the card is prep — thread, tasks, where and when. */
  | "upcoming"
  /** Under way. No thank-you yet: drafting one mid-interview is not a thing he needs offered. */
  | "live"
  /** Ended less than 48 hours ago: the card flips to follow-through. */
  | "followUp"
  /** Longer ago. The card still opens; it just no longer nudges. */
  | "past";

export function eventEnd(event: PlannerEvent): Date {
  const end = event.end ? new Date(event.end) : null;
  if (end && !Number.isNaN(end.getTime())) return end;
  return new Date(new Date(event.start).getTime() + DEFAULT_LENGTH_MS);
}

/**
 * Which state the card is in at `now`.
 *
 * "Ended" means `end < now`, strictly: at the minute it ends he is still shaking hands. The
 * window is half-open the other way — at exactly 48h it has closed — so "less than 48h ago"
 * in the spec means what it says at both edges.
 */
export function prepPhase(event: PlannerEvent, now: Date): PrepPhase {
  const start = new Date(event.start).getTime();
  const end = eventEnd(event).getTime();
  const t = now.getTime();
  if (t < start) return "upcoming";
  if (t <= end) return "live";
  if (t - end < FOLLOW_UP_WINDOW_MS) return "followUp";
  return "past";
}

export interface ThankYouDue {
  prep: PrepEvent;
  /** "2h ago", "35 min ago" — for the row. */
  endedAgo: string;
}

export function endedAgo(event: PlannerEvent, now: Date): string {
  const mins = Math.max(0, Math.round((now.getTime() - eventEnd(event).getTime()) / 60_000));
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.floor(hours / 24)} days ago`;
}

/**
 * The career conversations whose thank-you is due: ended less than 48h ago, most recent first,
 * minus any he already thanked from the card this session.
 *
 * Computed from whatever events the surface already has, once, when it renders — there is no
 * timer. `/api/week` starts today, so yesterday's chat is only here if the caller also passes
 * the day it was on; the caller unions what it has and this de-duplicates by id.
 */
export function thankYousDue(events: PlannerEvent[], now: Date, thanked: ReadonlySet<string> = new Set()): ThankYouDue[] {
  const seen = new Set<string>();
  const due: ThankYouDue[] = [];
  for (const event of events) {
    if (seen.has(event.id)) continue;
    seen.add(event.id);
    if (thanked.has(event.id)) continue;
    const prep = detectPrep(event);
    if (!prep || prepPhase(event, now) !== "followUp") continue;
    due.push({ prep, endedAgo: endedAgo(event, now) });
  }
  return due.sort((a, b) => eventEnd(b.prep.event).getTime() - eventEnd(a.prep.event).getTime());
}

// ---- What drafting may say --------------------------------------------------------------

/** Matches PlannerReplyRequest.maxInstructionBytes; the topic is trimmed well inside it. */
export const MAX_TOPIC = 200;

/**
 * The instruction sent with a thank-you draft.
 *
 * PRIVACY. Drafting already transmits the thread's subject, sender and snippet — the engine
 * re-reads those from its own copy of the message id. This instruction is the ONLY other thing
 * that leaves, so it carries nothing from the calendar: no title, no firm, no place, no time,
 * no attendee. "Today" or "yesterday" is the one concession, because a thank-you that does
 * not know when the conversation was reads as a template. The optional topic is the one line
 * he typed himself, for exactly this purpose.
 */
export function thankYouInstruction(event: PlannerEvent, now: Date, topic = ""): string {
  const when = relativeDay(eventEnd(event), now);
  const conversation = when ? `${when}'s conversation` : "our recent conversation";
  const base =
    `Write a short, warm thank-you note for ${conversation}. ` +
    "Keep it to a few sentences, specific rather than generic, and end by saying I look forward to staying in touch.";
  const typed = topic.replace(/\s+/g, " ").trim().slice(0, MAX_TOPIC);
  return typed ? `${base} Mention that I appreciated what we discussed about: ${typed}` : base;
}

/** "today" / "yesterday" in Vancouver, or null when it was longer ago than that. */
function relativeDay(when: Date, now: Date): "today" | "yesterday" | null {
  const key = (d: Date) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: "America/Vancouver", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  if (key(when) === key(now)) return "today";
  if (key(when) === key(new Date(now.getTime() - 24 * 60 * 60 * 1000))) return "yesterday";
  return null;
}

/** The subject for a thank-you with no thread to answer — he enters the address himself. */
export function thankYouSubject(prep: PrepEvent): string {
  return prep.firms.length > 0 ? `Thank you — ${prep.label}` : `Thank you — ${prep.event.title}`;
}
