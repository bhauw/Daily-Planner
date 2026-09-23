import { describe, expect, it } from "vitest";
import { findMeetingTimes, titleFromSubject } from "./meetingTime";

// Monday 21 September 2026, 09:00 local.
const REF = new Date(2026, 8, 21, 9, 0);
const NOW = REF;

function one(text: string) {
  const found = findMeetingTimes(text, REF, NOW);
  expect(found.length, text).toBeGreaterThan(0);
  return found[0];
}

function hm(d: Date) {
  return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

describe("findMeetingTimes", () => {
  it("reads a weekday and a time as one appointment", () => {
    const m = one("Would Thursday at 2pm work for a coffee chat?");
    expect(hm(m.start)).toBe("9/24 14:00");
    expect(hm(m.end)).toBe("9/24 14:30");
    expect(m.hasTime).toBe(true);
    expect(m.source).toBe("Thursday at 2pm");
  });

  it("takes both ends of a range", () => {
    const m = one("The midterm is Sept 25, 14:30 to 16:20 in AQ 3150.");
    expect(hm(m.start)).toBe("9/25 14:30");
    expect(hm(m.end)).toBe("9/25 16:20");
  });

  it("reads 'Thursday, September 24' as one day, not two", () => {
    const found = findMeetingTimes("Are you free Thursday, September 24 at 10:30am?", REF, NOW);
    expect(found).toHaveLength(1);
    expect(hm(found[0].start)).toBe("9/24 10:30");
  });

  it("handles tomorrow, noon, and a time written before the day", () => {
    expect(hm(one("Lunch tomorrow at noon?").start)).toBe("9/22 12:00");
    expect(hm(one("Can we do 3:15 pm on Friday").start)).toBe("9/25 15:15");
  });

  it("joins a day in the subject with a time in the body when there is one of each", () => {
    expect(hm(one("Interview Thursday — lots to cover before we get there. Can you do 14:30?").start)).toBe("9/24 14:30");
  });

  it("reads a bare afternoon hour as pm and a 24-hour time as written", () => {
    expect(hm(one("Friday 3:00 works").start)).toBe("9/25 15:00");
    expect(hm(one("Friday 09:00 works").start)).toBe("9/25 09:00");
  });

  it("offers a day with no time as a placeholder to edit", () => {
    const m = one("Let's catch up Wednesday.");
    expect(m.hasTime).toBe(false);
    expect(hm(m.start)).toBe("9/23 09:00");
  });

  it("means NEXT week when the weekday is today", () => {
    expect(hm(one("See you Monday at 1pm").start)).toBe("9/28 13:00");
  });

  it("never offers a time that has already passed", () => {
    expect(findMeetingTimes("That was on September 1 at 2pm.", REF, NOW)).toEqual([]);
    expect(findMeetingTimes("Met 2026-09-01 at 2pm", REF, NOW)).toEqual([]);
    expect(findMeetingTimes("today at 8am", REF, NOW)).toEqual([]);
  });

  it("rolls a month-day long past into next year", () => {
    expect(hm(one("Kickoff is January 12 at 9:30am").start)).toBe("1/12 09:30");
    expect(one("Kickoff is January 12 at 9:30am").start.getFullYear()).toBe(2027);
  });

  it("does not read prose as a date", () => {
    expect(findMeetingTimes("I sat 3 exams and you may 2 of them.", REF, NOW)).toEqual([]);
    expect(findMeetingTimes("The price rose 4% this quarter.", REF, NOW)).toEqual([]);
  });

  it("finds nothing in an email with no date", () => {
    expect(findMeetingTimes("Thanks for the notes, very helpful.", REF, NOW)).toEqual([]);
  });
});

describe("titleFromSubject", () => {
  it("strips reply prefixes and trailing punctuation", () => {
    expect(titleFromSubject("Re: Fwd: Coffee chat?")).toBe("Coffee chat");
    expect(titleFromSubject("   ")).toBe("Meeting");
  });
});
