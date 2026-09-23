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
//
// `@media … {` openers are dropped too, so a rule inside one is read like any other and its
// stray closing brace becomes an empty rule the parser skips. The assertions below that care
// about EVERY window size (the email's line floor) must see the media-query rules as well.
const CSS = readFileSync(join(HERE, "mail.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/@media[^{]*\{/g, "");
// The "Offer times" picker renders inside the editor pane but is styled in compose.css, because
// the composer uses it too. Read both so a scroller added there is caught here.
const COMPOSE_CSS = readFileSync(join(HERE, "../../compose/compose.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const OFFER_TSX = readFileSync(join(HERE, "../../compose/OfferTimes.tsx"), "utf8");
const APP_CSS = readFileSync(join(HERE, "../../app.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

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
  it("has exactly ONE scrolling region in the attached workspace, plus the opened email", () => {
    // Every rule in the file, not the text before the first `.mail--detached`: that split
    // silently skipped everything declared after the detached block, which is where the
    // triage and reply rules live — so it counted half the file and called it the whole.
    //
    // The thread pane scrolls via .scroll-y, not mail.css. The ONE exception here is the email
    // body while he has opened it — his call, 2026-09-22 — so exactly one attached rule may
    // scroll, and it is the open modifier.
    const scrolling: string[] = [];
    for (const rule of CSS.split("}")) {
      const [head, body] = rule.split("{");
      if (!body || !/overflow-y:\s*auto/.test(body)) continue;
      const attached = head.split(",").map((x) => x.trim()).filter((x) => !x.includes(".mail--detached"));
      scrolling.push(...attached);
    }
    expect(scrolling).toEqual([".message__body--open"]);
  });

  it("does not reintroduce a scroller inside the editor or the context pane", () => {
    for (const selector of [".ctx__notes-list", ".message__body", ".message", ".ctx", ".editor", ".reply"]) {
      expect(block(selector), selector).not.toContain("overflow-y: auto");
    }
  });

  it("clamps a closed email instead of scrolling it", () => {
    // A hard clip would look like text that simply ended; the clamp shows there is more.
    const body = block(".message__body");
    expect(body).toContain("line-clamp");
    expect(body).toContain("overflow: hidden");
  });

  it("caps the opened email so the reply and the footer stay on screen", () => {
    expect(block(".message__body--open")).toMatch(/max-height:\s*\d+vh/);
  });

  /*
   * Found only by rendering it: a long opened email made the page itself taller than the window,
   * and every `overflow: hidden` pane then clipped its bottom — Approve / Reject first. Two grid
   * items were sizing to their content. jsdom cannot see that, so the rules that stop it are
   * pinned here instead.
   */
  it("keeps the page exactly the window, so no pane is taller than the screen", () => {
    const main = APP_CSS.split("}").find((r) => r.split("{")[0].trim() === ".app__main");
    expect(main).toContain("min-height: 0");
    expect(block(".mail")).toContain("grid-template-rows: minmax(0, 1fr)");
  });

  it("keeps Approve right under a real thread's reply instead of at the bottom of the screen", () => {
    // "the approve is so far away": the reply stretched to fill the pane and pushed the footer
    // to the bottom edge. In a real thread it is content-height now.
    expect(block(".editor > .field--triage")).toContain("flex: 0 1 auto");
    expect(block(".field--triage .reply")).toContain("flex: 0 1 auto");
  });
  it("still scrolls as one column when detached into its own window", () => {
    // A narrow detached window scrolls as a page; fixed panes would squeeze the
    // editor into a third of it while the page scrolled anyway.
    expect(block(".mail--detached")).toContain("overflow-y: auto");
    expect(block(".mail--detached .mail__editor-pane")).toContain("overflow: visible");
  });

  /*
   * "Offer times" opens a picker inside the middle pane. Five slots as a list would have been the
   * obvious build and the first thing to need a scroller, so it is counted: no `.offer` rule may
   * scroll and the component may not opt into `scroll-y`.
   */
  it("adds no scroller with the Offer times picker", () => {
    const offerRules = COMPOSE_CSS.split("}").filter((rule) => {
      const [head, body] = rule.split("{");
      return body && head.split(",").some((sel) => sel.trim().startsWith(".offer"));
    });
    expect(offerRules.length).toBeGreaterThan(0);
    for (const rule of offerRules) expect(rule).not.toMatch(/overflow(-y)?:\s*(auto|scroll)/);
    expect(OFFER_TSX).not.toContain("scroll-y");
    expect(block(".field--triage .reply--offering .reply__body")).not.toContain("overflow-y: auto");
  });
});

/*
 * The email is the thing he came to read, so it is the one thing that never gives way.
 *
 * It did: the email was the only shrinkable element in the middle pane, so on a 13" MacBook
 * (1280x800) and at 1024x768 it collapsed to 0px and the booking chips painted over the "Email"
 * label and "Show whole email" — you could not read any email in the workbench. Pinned against
 * the stylesheet because jsdom has no layout; the screenshots at four sizes are in the commit.
 */
describe("the email always gets a readable share of the middle pane", () => {
  const LINE_FLOOR = 8;

  it("never shrinks the closed email: it is sized by its clamp, not by what is left over", () => {
    expect(block(".message")).toContain("flex: 0 0 auto");
    expect(block(".message__body")).toContain("flex: 0 0 auto");
  });

  it(`clamps to at least ${LINE_FLOOR} lines at every window size`, () => {
    const clamps = [...block(".message__body").matchAll(/(?:^|[^-])line-clamp:\s*(\d+)/g)].map((m) => Number(m[1]));
    expect(clamps.length).toBeGreaterThan(0);
    for (const n of clamps) expect(n).toBeGreaterThanOrEqual(LINE_FLOOR);
  });

  it(`gives the opened email a floor of ${LINE_FLOOR} lines, so a summary cannot squeeze it to 1px`, () => {
    const open = block(".message__body--open");
    expect(open).toMatch(new RegExp(`min-height:\\s*calc\\([^;]*\\*\\s*${LINE_FLOOR}\\)`));
    expect(open).not.toContain("min-height: 0");
  });

  it("makes the reply text box, not the email, the part that gives way", () => {
    // The reply's automatic minimum is its controls plus a one-row box; only the box shrinks.
    expect(block(".field--triage .reply")).toContain("min-height: 0");
    expect(block(".reply")).not.toContain("min-content");
    const box = block(".field--triage .reply__body");
    expect(box).toMatch(/min-height:\s*\d+px/);
    expect(box).toMatch(/flex:\s*0 1 \d+px/);
  });

  it("keeps the reply compact until he uses it, then grows it to a cap", () => {
    const compact = Number(/flex:\s*0 1 (\d+)px/.exec(block(".field--triage .reply__body"))?.[1]);
    const grown = Number(/flex-basis:\s*(\d+)px/.exec(block(".field--triage .reply--open .reply__body"))?.[1]);
    expect(compact).toBeGreaterThan(0);
    expect(compact).toBeLessThanOrEqual(64);
    expect(grown).toBeGreaterThan(compact);
    expect(grown).toBeLessThanOrEqual(200);
  });

  it("puts the booking chips in the flow under the email, never on top of it", () => {
    const bookit = block(".bookit");
    expect(bookit).toContain("flex: 0 0 auto");
    expect(bookit).not.toMatch(/position:\s*(absolute|fixed)/);
  });

  it("keeps the plan surface's .review margin out of the mail review box", () => {
    // Found by rendering at 1024x768: that 16px was the difference between fitting and not.
    expect(block(".editor > .review")).toContain("margin-top: 0");
  });

  it("keeps the footer to one row, so it never takes a second line of the email's height", () => {
    expect(block(".editor__actions-note")).toMatch(/flex:\s*1 1/);
  });

  it("fits all three columns beside the sidebar in a 1024px window", () => {
    const columns = /grid-template-columns:\s*([^;]+);/.exec(CSS.split("}").find((r) => r.split("{")[0].trim() === ".mail")!)![1];
    const mins = [...columns.matchAll(/minmax\((\d+)px/g)].map((m) => Number(m[1]));
    expect(mins).toHaveLength(3);
    const sidebar = 186; // --sidebar-width in tokens.css
    expect(sidebar + mins.reduce((a, b) => a + b, 0)).toBeLessThanOrEqual(1024);
  });
});
