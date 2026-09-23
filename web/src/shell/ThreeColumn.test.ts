/*
 * "Next scan 21:00 · Vancouver" was a string literal: it showed after 21:00, and it would have
 * gone on showing 21:00 whatever the schedule said. It comes from the engine's scanTimes now.
 */

import { describe, expect, it } from "vitest";
import { nextScanLabel } from "./ThreeColumn";

const slots = ["2026-09-14T06:00:00-07:00", "2026-09-14T12:00:00-07:00", "2026-09-14T21:00:00-07:00"];

describe("nextScanLabel", () => {
  it("names the next of the engine's scan times", () => {
    expect(nextScanLabel(slots, new Date("2026-09-14T09:30:00-07:00"))).toBe("Next scan 12:00 · Vancouver");
    expect(nextScanLabel(slots, new Date("2026-09-14T16:30:00-07:00"))).toBe("Next scan 21:00 · Vancouver");
  });

  it("does not claim a scan that has already happened", () => {
    expect(nextScanLabel(slots, new Date("2026-09-14T22:00:00-07:00"))).toBe("No more scans today");
  });

  it("says nothing when the engine's settings could not be read", () => {
    expect(nextScanLabel(null, new Date("2026-09-14T09:30:00-07:00"))).toBeNull();
    expect(nextScanLabel([], new Date("2026-09-14T09:30:00-07:00"))).toBeNull();
  });
});
