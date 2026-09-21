/*
 * The conversion between a form field and an instant.
 *
 * This is the highest-risk pure logic in the write path. A <input
 * type="datetime-local"> hands back "2026-09-16T09:00" with no offset at all,
 * and the obvious `new Date(value)` reads it in the machine's zone — right by
 * accident here, wrong on a machine set to anything else, and an hour out
 * across a DST boundary on every machine. An hour's drift writes the wrong time
 * onto a real calendar and nothing downstream would question it.
 */

import { describe, expect, it } from "vitest";
import { addMinutesToInput, fromLocalInput, minutesBetweenInputs, toLocalInput } from "./datetime";

describe("form value → instant", () => {
  it("reads a summer time as PDT, not as UTC and not as the machine's zone", () => {
    // 09:00 in Vancouver in September is 16:00Z. Reading it as UTC gives 09:00Z — seven hours
    // early, and an event that lands in the middle of the night.
    expect(fromLocalInput("2026-09-16T09:00")).toBe("2026-09-16T16:00:00.000Z");
  });

  it("reads a winter time as PST — one hour different from the summer rule", () => {
    // 09:00 in January is 17:00Z. A hardcoded −07:00 offset would put this at 16:00Z.
    expect(fromLocalInput("2026-01-16T09:00")).toBe("2026-01-16T17:00:00.000Z");
  });

  it("refuses anything it cannot read rather than guessing", () => {
    for (const bad of ["", "not a date", "2026-09-16", "2026-13-16T09:00", "2026-09-16T25:00", "2026-09-16T09:61"]) {
      expect(fromLocalInput(bad)).toBeNull();
    }
  });

  it("refuses a year that is obviously a typo", () => {
    // "2062" is one keystroke from "2026". The engine bounds an event's DURATION, which does
    // not catch a start and end that are both mistyped by the same forty years.
    expect(fromLocalInput("1926-09-16T09:00")).toBeNull();
    expect(fromLocalInput("2262-09-16T09:00")).toBeNull();
    expect(fromLocalInput("2062-09-16T09:00")).not.toBeNull();
  });
});

describe("instant → form value", () => {
  it("round-trips through the planner's zone", () => {
    const value = "2026-09-16T14:30";
    expect(toLocalInput(fromLocalInput(value)!)).toBe(value);
  });

  it("renders an instant as the wall clock in the planner's zone, not the machine's", () => {
    expect(toLocalInput("2026-09-16T16:00:00.000Z")).toBe("2026-09-16T09:00");
  });

  it("returns empty for an unreadable instant instead of throwing mid-render", () => {
    expect(toLocalInput("not-a-date")).toBe("");
  });
});

describe("duration arithmetic", () => {
  it("adds minutes in wall-clock terms", () => {
    expect(addMinutesToInput("2026-09-16T09:00", 90)).toBe("2026-09-16T10:30");
    expect(addMinutesToInput("2026-09-16T23:30", 60)).toBe("2026-09-17T00:30");
  });

  it("keeps a duration a duration across the DST boundary", () => {
    // On the spring-forward day the wall clock skips an hour. "An hour later" on this form
    // means the clock reads an hour later — the user picked a time on a clock face.
    expect(addMinutesToInput("2026-03-08T01:30", 60)).toBe("2026-03-08T02:30");
  });

  it("measures the gap between two values", () => {
    expect(minutesBetweenInputs("2026-09-16T09:00", "2026-09-16T10:30")).toBe(90);
    expect(minutesBetweenInputs("2026-09-16T10:30", "2026-09-16T09:00")).toBe(-90);
    expect(minutesBetweenInputs("bad", "2026-09-16T09:00")).toBeNull();
  });

  it("leaves an unreadable value alone rather than corrupting it", () => {
    expect(addMinutesToInput("nonsense", 30)).toBe("nonsense");
  });
});
