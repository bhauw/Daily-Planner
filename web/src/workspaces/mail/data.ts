/*
 * Synthetic draft detail for the Mail workbench (read-only round).
 *
 * The engine's /api/drafts returns a THIN Draft ({id,title,summary,kind}) — the
 * list. The workbench needs the richer per-draft detail an editor shows (body,
 * subject, the immutable review fields, and the context the assistant used). All
 * of that is synthetic this round, so it lives here in the workspace rather than
 * on the wire. When the real editor endpoint lands, this module is what it
 * replaces — the component code above it does not change.
 *
 * SAFETY: `context` carries COUNTS and CATEGORIES only. There is deliberately no
 * field for a vault note title, a vault path, or the excluded-calendar identity —
 * the type cannot express them, so the UI cannot leak them.
 */

import type { Category, Draft } from "../contract";

/** A recipient address, shown in full — never truncated into ambiguity. */
export interface Recipient {
  name: string;
  address: string;
}

/** An attachment shown as name + size only. No path, ever. */
export interface Attachment {
  name: string;
  size: string; // human string, e.g. "184 KB"
}

/** What the assistant used — counts and categories only. Never content. */
export interface ContextUsedData {
  threadMessages: number;
  calendarConflicts: number;
  /** vault notes referenced, by category and count — never a title or path. */
  vaultNotes: { category: Category; count: number }[];
}

/** Whether this draft's eventual action sends externally (irreversible). */
export function isSendAction(kind: Draft["kind"]): boolean {
  // A reply sends an email — the one irreversible "send" this product performs.
  return kind === "reply";
}

export interface DraftDetail {
  /**
   * True when this row is a REAL inbox thread surfaced for triage rather than a proposed
   * draft. Nothing has been written for it, so the editor must not present an approvable
   * body — see the notice in DraftEditor. Draft generation arrives in a later milestone.
   */
  isTriage: boolean;
  /** The thread's own snippet, shown read-only. Never treated as a draft body. */
  snippet: string;
  /** category for the thread chip — Draft on the wire has none this round. */
  category: Category;
  subject: string;
  body: string;
  // Immutable review fields — displayed, never inline-editable.
  to: Recipient[];
  cc: Recipient[];
  bcc: Recipient[];
  attachments: Attachment[];
  labels: string[];
  context: ContextUsedData;
}

const DETAIL: Record<string, DraftDetail> = {
  d1: {
    isTriage: false,
    snippet: "",
    category: "career",
    subject: "Re: Project interview — interview time",
    body:
      "Hi Priya,\n\n" +
      "Thank you for the invitation. Thursday at 14:30 conflicts with another commitment, " +
      "so I want to avoid proposing a time I can't hold.\n\n" +
      "Would Friday at 10:00 work instead? I'm clear from 09:00 to 18:00 that day and can " +
      "come to the office or meet over video — whichever is easier for the team.\n\n" +
      "Best,\nArief",
    to: [{ name: "Alex Morgan", address: "alex@example.test" }],
    cc: [{ name: "Recruiting Team", address: "recruiting@example.test" }],
    bcc: [],
    attachments: [],
    labels: ["Career", "Recruiting"],
    context: {
      threadMessages: 4,
      calendarConflicts: 1,
      vaultNotes: [
        { category: "career", count: 2 },
        { category: "school", count: 1 },
      ],
    },
  },
  d2: {
    isTriage: false,
    snippet: "",
    category: "career",
    subject: "Team coffee chat — hold + prep",
    body:
      "Creates a calendar hold for the team coffee chat, a 25-minute buffer before it, " +
      "and a prep task the evening before. Nothing is added to your calendar until you approve.",
    to: [],
    cc: [],
    bcc: [],
    attachments: [],
    labels: ["Career"],
    context: {
      threadMessages: 2,
      calendarConflicts: 0,
      vaultNotes: [{ category: "career", count: 1 }],
    },
  },
  d3: {
    isTriage: false,
    snippet: "",
    category: "career",
    subject: "Re: Team meeting — reschedule",
    body:
      "Hi Jordan,\n\n" +
      "Thanks for the flexibility. Two windows that clear my 09:00–18:00 rule this week:\n" +
      "  • Wednesday 11:00–11:45\n" +
      "  • Thursday 16:15–17:00\n\n" +
      "Either works for me — let me know which suits you and I'll confirm.\n\n" +
      "Best,\nArief",
    to: [{ name: "Jordan Lee", address: "jordan@example.test" }],
    cc: [],
    bcc: [],
    attachments: [{ name: "availability.ics", size: "3 KB" }],
    labels: ["Career", "Recruiting"],
    context: {
      threadMessages: 3,
      calendarConflicts: 0,
      vaultNotes: [{ category: "career", count: 1 }],
    },
  },
};

/**
 * Detail for a draft id. Falls back to a safe synthetic detail for ids the
 * engine returns that we have no fixture for — so the workbench never blanks
 * out and never invents provider content beyond the summary already on the wire.
 */
export function detailFor(draft: Draft): DraftDetail {
  const known = DETAIL[draft.id];
  if (known) return known;

  // A real inbox thread (it carries a sender). This round is triage only: show the thread and
  // say plainly that no reply exists yet. Putting the snippet in `body` would dress a received
  // message up as an approvable draft, which is exactly the thing this product must not do.
  const isTriage = typeof draft.sender === "string" && draft.sender.length > 0;
  return {
    isTriage,
    snippet: isTriage ? draft.summary : "",
    category: draft.category ?? "other",
    subject: draft.title,
    body: isTriage ? "" : draft.summary,
    to: isTriage ? [{ name: draft.sender as string, address: "" }] : [],
    cc: [],
    bcc: [],
    attachments: [],
    labels: [],
    context: { threadMessages: 1, calendarConflicts: 0, vaultNotes: [] },
  };
}
