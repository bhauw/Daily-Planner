/*
 * WCAG 2.5.8 Target Size (Minimum): the "Show excluded reference calendars" checkbox measured
 * 13×13 CSS px (need >= 24×24, or an equivalent spacing exception, which does not apply to a
 * standalone settings checkbox) — audit finding #10.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC = dirname(fileURLToPath(import.meta.url));
const CSS = readFileSync(join(SRC, "calendar.css"), "utf8");

/** The block body for the first top-level rule matching `selector`, brace-balanced. */
function blockFor(source: string, selector: string): string {
  const start = source.indexOf(selector);
  if (start === -1) throw new Error(`selector ${selector} not found in calendar.css`);
  const open = source.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  throw new Error(`unbalanced braces after ${selector}`);
}

function pxProp(block: string, prop: string): number {
  const m = block.match(new RegExp(`${prop}:\\s*([\\d.]+)px`));
  if (!m) throw new Error(`${prop} not set as a plain px value`);
  return Number.parseFloat(m[1]);
}

describe("the excluded-calendars checkbox clears the 24px minimum target size", () => {
  it("the row is at least 24px tall", () => {
    const row = blockFor(CSS, ".excluded-toggle {");
    expect(pxProp(row, "min-height")).toBeGreaterThanOrEqual(24);
  });

  it("the checkbox itself is at least 20px in both dimensions", () => {
    const box = blockFor(CSS, ".excluded-toggle__box {");
    expect(pxProp(box, "width")).toBeGreaterThanOrEqual(20);
    expect(pxProp(box, "height")).toBeGreaterThanOrEqual(20);
  });
});
