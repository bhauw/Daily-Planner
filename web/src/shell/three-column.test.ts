/*
 * 200% zoom (WCAG 1.4.10 Reflow): three-column.css had zero @media queries, and
 * 2×--column-min + --assistant-width already floors past a 720 CSS px viewport (= 1440×900 at
 * 200%), so every route got a horizontal scrollbar with controls partly off-screen (audit
 * finding #9). Below a breakpoint set above that floor, .threecol stacks into one column
 * instead of forcing 2D scroll.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC = dirname(fileURLToPath(import.meta.url));
const CSS = readFileSync(join(SRC, "three-column.css"), "utf8");
const TOKENS = readFileSync(join(SRC, "../tokens.css"), "utf8");

function tokenPx(name: string): number {
  const m = TOKENS.match(new RegExp(`\\n\\s*${name}:\\s*([0-9.]+)px;`));
  if (!m) throw new Error(`token ${name} not declared, or not a plain px value`);
  return Number.parseFloat(m[1]);
}

/** The block body for the first top-level rule matching `selector`, brace-balanced. */
function blockFor(source: string, selector: string): string {
  const start = source.indexOf(selector);
  if (start === -1) throw new Error(`selector ${selector} not found`);
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

describe("three-column.css reflows under 200% zoom", () => {
  const mediaMatch = CSS.match(/@media\s*\(max-width:\s*(\d+)px\)/);

  it("has a max-width media query", () => {
    expect(mediaMatch).not.toBeNull();
  });

  it("sets the breakpoint above the floor 2×--column-min + --assistant-width can reach", () => {
    const floor = 2 * tokenPx("--column-min") + tokenPx("--assistant-width");
    const breakpoint = Number(mediaMatch![1]);
    expect(breakpoint).toBeGreaterThanOrEqual(floor);
    // And above the 720 CSS px viewport the audit measured 200% zoom at.
    expect(breakpoint).toBeGreaterThanOrEqual(720);
  });

  it("collapses .threecol to a single column inside that media query", () => {
    const mediaBody = blockFor(CSS, mediaMatch![0]);
    const threecolInMedia = blockFor(mediaBody, ".threecol {");
    expect(threecolInMedia).toMatch(/grid-template-columns:\s*1fr\s*;/);
  });
});
