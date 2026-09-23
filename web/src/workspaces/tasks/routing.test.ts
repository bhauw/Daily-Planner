/*
 * Quick-capture routing: every assumption visible, and visibly the right one.
 *
 * The reason used to quote the text's FIRST word ("“I” signals coursework"),
 * the first category with any hit won ("coffee chat with Example Corp … midterm"
 * went to School), and anything unrecognised silently landed in whichever list
 * happened to be last (Extracurricular), which the copy called "the catch-all".
 */

import { describe, expect, it } from "vitest";
import { routeCapture } from "./routing";

const DAY = "2026-09-14"; // a Monday
const MOCK_LISTS = ["School", "Career", "Finance", "Personal", "Extracurricular"];

describe("which list, and why", () => {
  it("quotes the keyword that matched, not the first word", () => {
    const r = routeCapture("I need to finish the midterm review", DAY, MOCK_LISTS);
    expect(r.listName).toBe("School");
    expect(r.reasons[0]).toContain("“midterm”");
    expect(r.reasons[0]).not.toContain("“I”");
  });

  it("scores every category: a Example Corp coffee chat is Career even when it mentions a midterm", () => {
    const r = routeCapture("coffee chat with Example Corp senior about midterm prep", DAY, MOCK_LISTS);
    expect(r.listName).toBe("Career");
    expect(r.reasons[0]).toMatch(/Example Corp|coffee chat/);
  });

  it("routes a short 'Example Corp coffee chat' to Career", () => {
    expect(routeCapture("Example Corp coffee chat", DAY, MOCK_LISTS).listName).toBe("Career");
  });

  it("matches whole words — 'classic' is not a class, 'bus' needs no trailing space", () => {
    expect(routeCapture("watch a classic film", DAY, MOCK_LISTS).category).toBe("other");
    expect(routeCapture("ECONOMICS 250 problem set", DAY, MOCK_LISTS).listName).toBe("School");
  });

  it("sends unrecognised text to a neutral list when one exists", () => {
    const r = routeCapture("Finish case comp deck", DAY, [...MOCK_LISTS, "General"]);
    expect(r.listName).toBe("General");
    expect(r.needsListChoice).toBe(false);
  });

  it("never silently drops unrecognised text into Extracurricular — it asks", () => {
    const r = routeCapture("Finish case comp deck", DAY, MOCK_LISTS);
    expect(r.listName).toBe("");
    expect(r.needsListChoice).toBe(true);
    expect(r.reasons[0]).toContain("No clear match — pick a list");
  });
});

describe("due dates in the ways students write them", () => {
  it.each([
    ["Submit PwC application by Sept 30", "2026-09-30"],
    ["Submit PwC application 9/30", "2026-09-30"],
    ["Submit PwC application Sep 30", "2026-09-30"],
    ["essay due October 2", "2026-10-02"],
    ["finish slides by Fri", "2026-09-18"],
  ])("%s → %s", (text, due) => {
    expect(routeCapture(text, DAY, MOCK_LISTS).due).toBe(due);
  });

  it("rolls a date that has already passed this year into next year", () => {
    expect(routeCapture("renew passport by Jan 5", DAY, MOCK_LISTS).due).toBe("2027-01-05");
  });

  it("says which words it read the date from", () => {
    const r = routeCapture("Submit PwC application by Sept 30", DAY, MOCK_LISTS);
    expect(r.reasons.join(" ")).toContain("“Sept 30”");
  });
});
