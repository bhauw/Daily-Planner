/*
 * Grouping the triaged inbox for display.
 *
 * The ORDER is not decided here — the engine already ranked the list, and re-deriving a rank
 * in the client is how Focus and Digest ended up colouring the same event two different ways.
 * This only cuts the ranked list into the sections a reader sees, preserving the order it
 * arrived in.
 */

import type { Category, Draft, MailReason } from "../api/client";

/** The category order the engine ranks by, mirrored here only for SECTION order. */
export const MAIL_CATEGORY_ORDER: Category[] = ["school", "career", "finance", "personal", "other"];

/** What each section is called on the Digest. `career` is "Recruiting" in a mail context. */
export const MAIL_CATEGORY_LABEL: Record<string, string> = {
  school: "School",
  career: "Recruiting",
  finance: "Finance",
  personal: "Personal",
  other: "Other",
  commute: "Commute",
  work: "Work",
};

export interface MailGroup {
  key: string;
  title: string;
  drafts: Draft[];
}

export interface GroupedMail {
  /** The override band, in arrival-ranked order. Empty when nothing is urgent. */
  urgent: Draft[];
  /** One group per category that actually has mail. Empty categories are not rendered. */
  groups: MailGroup[];
  unreadCount: number;
}

/**
 * Cuts a ranked list into sections.
 *
 * Only rows the engine triaged (`band` present) are sectioned. Anything untriaged — synthetic
 * sample content — falls into its category group, so the sample day still renders rather than
 * vanishing into an empty surface.
 */
export function groupMail(drafts: Draft[]): GroupedMail {
  const replies = drafts.filter((d) => d.kind === "reply");
  const urgent = replies.filter((d) => d.band === "urgent");
  const rest = replies.filter((d) => d.band !== "urgent");

  const groups: MailGroup[] = [];
  for (const category of MAIL_CATEGORY_ORDER) {
    const inCategory = rest.filter((d) => (d.category ?? "other") === category);
    if (inCategory.length > 0) {
      groups.push({ key: category, title: MAIL_CATEGORY_LABEL[category], drafts: inCategory });
    }
  }
  // A category outside the stated order (commute, work) still has to appear, or its mail is
  // invisible. It goes after the ranked ones, which is where the engine sorts it too.
  const ranked = new Set<string>(MAIL_CATEGORY_ORDER);
  const leftovers = rest.filter((d) => !ranked.has(d.category ?? "other"));
  for (const draft of leftovers) {
    const key = draft.category ?? "other";
    const existing = groups.find((g) => g.key === key);
    if (existing) existing.drafts.push(draft);
    else groups.push({ key, title: MAIL_CATEGORY_LABEL[key] ?? key, drafts: [draft] });
  }

  return {
    urgent,
    groups,
    // `unread` is absent on untriaged content. Absent is not unread.
    unreadCount: replies.filter((d) => d.unread === true).length,
  };
}

/** The badge a row in the urgent band shows. */
export const REASON_LABEL: Record<MailReason, string> = {
  security: "Security",
  interview: "Interview",
  deadline: "Deadline",
  obligation: "Payment",
  category: "",
};
