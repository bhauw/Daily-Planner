/*
 * One pane scrolls: the thread list.
 *
 * When all three panes scrolled, reviewing a draft slid the status stepper off
 * the top and the Approve / Reject footer off the bottom, and a long recipient
 * list pushed the "To" line out of view — so it was possible to approve a send
 * with the thing you are meant to be checking off-screen. That is a layout bug
 * with a safety consequence, which is why it is pinned here rather than left to
 * be re-broken by the next person who adds a field to the editor.
 *
 * jsdom has no layout engine, so these read the real source the way
 * contrast.test.ts reads the real stylesheets: the rule is enforced rather than
 * described in a comment that drifts.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const HERE = dirname(fileURLToPath(import.meta.url));
const WORKBENCH = readFileSync(join(HERE, "DraftWorkbench.tsx"), "utf8");
// Comments are stripped before parsing: a comment sitting directly above a rule
// otherwise becomes part of the selector text and the rule is never found —
// which reads as "the declaration is missing" rather than "the parser is wrong".
const CSS = readFileSync(join(HERE, "mail.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

/**
 * Every declaration that applies to `selector`, from all of its rules joined.
 *
 * All of them, not the first: a selector is legitimately declared more than
 * once here (`.mail--detached` sets its height in one rule and its scrolling in
 * another), and reading only the first would assert against half the truth.
 */
function block(selector: string): string {
  const found: string[] = [];
  for (const rule of CSS.split("}")) {
    const [head, body] = rule.split("{");
    if (!body) continue;
    const selectors = head.split(",").map((s) => s.trim());
    if (selectors.includes(selector)) found.push(body);
  }
  if (found.length === 0) throw new Error(`no rule for "${selector}"`);
  return found.join("\n");
}

describe("only the thread list scrolls", () => {
  it("puts scroll-y on exactly one pane", () => {
    const uses = WORKBENCH.match(/scroll-y/g) ?? [];
    expect(uses).toHaveLength(1);
  });

  it("and that pane is the thread list, not the editor or the context", () => {
    expect(WORKBENCH).toContain('className="mail__pane mail__threads-pane scroll-y"');
    expect(WORKBENCH).toContain('className="mail__pane mail__editor-pane"');
    expect(WORKBENCH).toContain('className="mail__pane mail__ctx-pane"');
  });

  it("makes the editor and context panes fixed-height columns that cannot scroll", () => {
    const panes = block(".mail__editor-pane");
    expect(panes).toContain("overflow: hidden");
    expect(panes).toContain("flex-direction: column");
  });

  it("keeps the editor exactly as tall as its pane", () => {
    const editor = block(".editor");
    expect(editor).toContain("min-height: 0");
    expect(editor).toContain("overflow: hidden");
    // `min-height: 100%` is what used to make the column outgrow the pane.
    expect(editor).not.toContain("min-height: 100%");
  });

  it("never lets the review fields or the action footer be scrolled away", () => {
    // They are fixed-basis, so the elastic body absorbs the slack instead.
    expect(block(".editor__actions")).toContain("flex: 0 0 auto");
  });

  it("gives the body no height floor, since a floor is what forced the scroll", () => {
    expect(block(".editor > .field--grow")).toContain("min-height: 0");
    const textarea = block(".field__textarea");
    expect(textarea).toContain("min-height: 0");
    // A resize handle would let the user push the footer back out of the pane.
    expect(textarea).toContain("resize: none");
  });

  /*
   * The rule stated plainly, and the one the first fix missed.
   *
   * That fix stopped the three PANES scrolling and left two scrollers inside them — the context
   * note list and the thread snippet — so the middle and right columns still moved under the
   * cursor and the bug was reported as unfixed. Counting is the only assertion that catches
   * that: naming the panes only ever proves the panes are right.
   */
  it("has exactly ONE scrolling region in the attached workspace", () => {
    // Split on the selector, not on a comment: comments are stripped before parsing.
    const attached = CSS.split(".mail--detached")[0];
    const scrollers = attached.match(/overflow-y:\s*auto/g) ?? [];
    expect(scrollers).toHaveLength(0); // the thread pane scrolls via .scroll-y, not mail.css
  });

  it("does not reintroduce a scroller inside the editor or the context pane", () => {
    for (const selector of [".ctx__notes-list", ".triage__snippet", ".ctx", ".editor"]) {
      expect(block(selector), selector).not.toContain("overflow-y: auto");
    }
  });

  it("clamps a long thread preview instead of scrolling it", () => {
    // A hard clip would look like text that simply ended; the clamp shows there is more.
    const snippet = block(".triage__snippet");
    expect(snippet).toContain("line-clamp");
    expect(snippet).toContain("overflow: hidden");
  });

  it("still scrolls as one column when detached into its own window", () => {
    // A narrow detached window scrolls as a page; fixed panes would squeeze the
    // editor into a third of it while the page scrolled anyway.
    expect(block(".mail--detached")).toContain("overflow-y: auto");
    expect(block(".mail--detached .mail__editor-pane")).toContain("overflow: visible");
  });
});
