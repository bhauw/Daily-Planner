import { describe, expect, it } from "vitest";
import type { Draft } from "../api/client";
import { MAIL_CATEGORY_ORDER, groupMail } from "./mailTriage";

/**
 * Grouping the ranked inbox.
 *
 * The one thing that must not happen here is re-sorting. The engine ranks the list; if this
 * file reorders it, the two disagree and the user sees a different "read first" depending on
 * which surface they opened — the same class of bug as Focus and Digest colouring one event
 * two different ways.
 */
function draft(over: Partial<Draft> & Pick<Draft, "id">): Draft {
  return {
    title: "Subject",
    summary: "",
    kind: "reply",
    ...over,
  } as Draft;
}

describe("groupMail", () => {
  it("keeps the order the engine sent, within each group", () => {
    // Deliberately handed over in the engine's ranked order. Grouping must not touch it.
    const ranked = [
      draft({ id: "s1", category: "school", band: "ordinary" }),
      draft({ id: "s2", category: "school", band: "ordinary" }),
      draft({ id: "s3", category: "school", band: "ordinary" }),
    ];
    expect(groupMail(ranked).groups[0].drafts.map((d) => d.id)).toEqual(["s1", "s2", "s3"]);
  });

  it("lifts the urgent band out, whatever category it is in", () => {
    const grouped = groupMail([
      draft({ id: "u", category: "other", band: "urgent", reason: "security" }),
      draft({ id: "s", category: "school", band: "ordinary" }),
    ]);
    expect(grouped.urgent.map((d) => d.id)).toEqual(["u"]);
    // And it is not ALSO in its category group — a row shown twice is a row you act on twice.
    expect(grouped.groups.flatMap((g) => g.drafts.map((d) => d.id))).toEqual(["s"]);
  });

  it("renders category sections in Braxton's order, skipping empty ones", () => {
    const grouped = groupMail([
      draft({ id: "p", category: "personal", band: "ordinary" }),
      draft({ id: "sc", category: "school", band: "ordinary" }),
      draft({ id: "f", category: "finance", band: "ordinary" }),
    ]);
    // Finance sits between school and personal; career has no mail and is not rendered.
    expect(grouped.groups.map((g) => g.key)).toEqual(["school", "finance", "personal"]);
    expect(grouped.groups.map((g) => g.title)).toEqual(["School", "Finance", "Personal"]);
  });

  it("calls the career category Recruiting on a mail surface", () => {
    const grouped = groupMail([draft({ id: "c", category: "career", band: "ordinary" })]);
    expect(grouped.groups[0].title).toBe("Recruiting");
  });

  it("shows mail in a category outside the stated order rather than losing it", () => {
    // `work` and `commute` are real categories that the priority list does not mention. They
    // must still appear, after the ranked ones — dropping them would hide real mail.
    const grouped = groupMail([
      draft({ id: "w", category: "work", band: "ordinary" }),
      draft({ id: "s", category: "school", band: "ordinary" }),
    ]);
    expect(grouped.groups.map((g) => g.key)).toEqual(["school", "work"]);
  });

  it("puts untriaged sample content in a group rather than dropping it", () => {
    // Synthetic content has no band. The sample day must still render.
    const grouped = groupMail([draft({ id: "x", category: "school" })]);
    expect(grouped.groups[0].drafts.map((d) => d.id)).toEqual(["x"]);
  });

  it("ignores rows that are not mail", () => {
    const grouped = groupMail([
      draft({ id: "b", kind: "bundle", category: "school" }),
      draft({ id: "m", kind: "reply", category: "school" }),
    ]);
    expect(grouped.groups.flatMap((g) => g.drafts.map((d) => d.id))).toEqual(["m"]);
  });

  it("counts unread, and does not read absent as unread", () => {
    const grouped = groupMail([
      draft({ id: "a", category: "school", unread: true }),
      draft({ id: "b", category: "school", unread: false }),
      draft({ id: "c", category: "school" }), // untriaged: absent, not unread
    ]);
    expect(grouped.unreadCount).toBe(1);
  });

  it("mirrors the engine's category order exactly", () => {
    // Break caught: this list drifts from MailTriagePolicy.categoryOrder, so sections render in
    // a different order than the rows were ranked in.
    expect(MAIL_CATEGORY_ORDER).toEqual(["school", "career", "finance", "personal", "other"]);
  });
});
