/*
 * The "Last scan" pill. Pinned: with no scan time from the engine it says "—", never a time —
 * the shell used to pass a hardcoded "12:00", which read as a real reading on every launch.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { SafetyRail } from "./SafetyRail";

let root: Root | null = null;
let host: HTMLElement | null = null;
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
});

function render(props: Parameters<typeof SafetyRail>[0]) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root!.render(createElement(SafetyRail, props)));
  return host.querySelector(".saferail__pill")!;
}

describe("SafetyRail last scan", () => {
  it("says unknown, not a time, when the engine reports none", () => {
    const pill = render({});
    expect(pill.textContent).toBe("Last scan —");
    expect(pill.getAttribute("aria-label")).toBe("Last scan not reported");
    expect(pill.textContent).not.toMatch(/\d/);
  });

  it("shows a time it is given", () => {
    const pill = render({ lastScan: "12:04" });
    expect(pill.textContent).toBe("Last scan 12:04");
    expect(pill.getAttribute("aria-label")).toBe("Last scan 12:04");
  });
});

// role="note" is not a landmark, so the persistent safety banner — on every route — sat outside
// the app's landmark structure and tripped axe's "content not contained by landmarks" check
// (audit finding #8). It already carries a real aria-label (the safety state's own wording), so
// role="region" makes it a uniquely named landmark rather than inventing a new label.
describe("SafetyRail landmark", () => {
  it("is a labelled region, not role=note", () => {
    const pill = render({ safety: { mode: "read-only", externalWrites: false, label: "Read-only · no external writes" } });
    const rail = pill.closest(".saferail")!;
    expect(rail.getAttribute("role")).toBe("region");
    expect(rail.getAttribute("aria-label")).toBe("Read-only · no external writes");
  });
});
