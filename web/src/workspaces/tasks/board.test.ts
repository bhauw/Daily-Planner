/*
 * Board layout guards: the 4th+ list column at 1440, and the sidebar's 44px hit target.
 *
 * At 1440 the focus-block pane used to take a fixed 360px and the list row a fixed-width flex
 * row, so the fourth column ("Personal") sat half behind the pane with no indication there was
 * more to see. The fix makes the columns a grid that shares space down to a floor and scrolls the
 * row (not the page) once they hit it, with a fade + chevron affordance at whichever edge is
 * clipped. These tests read the real stylesheets and source, the way contrast.test.ts and
 * mail/scroll.test.ts do, so the rule is enforced rather than merely described in a comment that
 * drifts.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { overflowEdges } from "./BoardScroller";

const HERE = dirname(fileURLToPath(import.meta.url));
const CSS = readFileSync(join(HERE, "tasks.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const BOARD_SCROLLER = readFileSync(join(HERE, "BoardScroller.tsx"), "utf8");
const SIDEBAR_CSS = readFileSync(join(HERE, "../../shell/sidebar-rail.css"), "utf8").replace(
  /\/\*[\s\S]*?\*\//g,
  "",
);
const TOKENS = readFileSync(join(HERE, "../../tokens.css"), "utf8");

/** Every declaration for `selector`, joined across all of its rules (it may be declared more than once). */
function block(css: string, selector: string): string {
  const found: string[] = [];
  for (const rule of css.split("}")) {
    const [head, body] = rule.split("{");
    if (!body) continue;
    if (head.split(",").map((s) => s.trim()).includes(selector)) found.push(body);
  }
  if (found.length === 0) throw new Error(`no rule for "${selector}"`);
  return found.join("\n");
}

function token(css: string, name: string): string {
  const m = css.match(new RegExp(`\\n\\s*${name}:\\s*([^;]+);`));
  if (!m) throw new Error(`token ${name} not declared`);
  return m[1].trim();
}

describe("task board: columns share space, then scroll", () => {
  it("sizes columns with a floor instead of a fixed width", () => {
    const list = block(CSS, ".tasklist");
    expect(list).not.toMatch(/width:\s*\d+px/);
    const lists = block(CSS, ".tasklists");
    expect(lists).toContain("display: grid");
    expect(lists).toMatch(/grid-template-columns:\s*repeat\(var\(--list-count/);
    expect(lists).toContain("minmax(var(--tasklist-min), 1fr)");
  });

  it("binds --list-count from the real number of lists, not a guess", () => {
    const listColumns = readFileSync(join(HERE, "ListColumns.tsx"), "utf8");
    expect(listColumns).toMatch(/"--list-count":\s*lists\.length/);
  });

  it("scrolls the row, not the page, when columns hit the floor", () => {
    const lists = block(CSS, ".tasks__lists");
    expect(lists).toContain("overflow-x: auto");
    expect(lists).toContain("overflow-y: hidden");
    // The board wrapper carries no scroll of its own — .tasks__lists is the only scroller.
    const board = block(CSS, ".tasks__board");
    expect(board).not.toMatch(/overflow(-x)?:\s*auto/);
  });

  it("gives the focus-block pane a shrinkable width instead of a fixed one", () => {
    // A fixed 360px pane is what ate the fourth column at 1440; the pane must now be able to
    // give width back to the board.
    const grid = block(CSS, ".tasks__grid");
    expect(grid).not.toMatch(/minmax\(0,\s*1fr\)\s+minmax\(\d+px,\s*\d+px\)/);
    expect(grid).toContain("var(--tasks-timeline-width)");
  });

  it("shows a visible cue, not a silent clip, at whichever edge has more columns", () => {
    expect(BOARD_SCROLLER).toContain("tasks__edge--start");
    expect(BOARD_SCROLLER).toContain("tasks__edge--end");
    // Each edge is a fade over the content, sized off the container's real scroll position.
    const start = block(CSS, ".tasks__edge--start");
    const end = block(CSS, ".tasks__edge--end");
    expect(start).toMatch(/background:\s*linear-gradient/);
    expect(end).toMatch(/background:\s*linear-gradient/);
  });

  it("keeps the paging chevrons out of the tab order and the accessibility tree", () => {
    // They are a pointer convenience only: the scroll region itself is the keyboard/AT target.
    expect(BOARD_SCROLLER).toMatch(/className="tasks__edge tasks__edge--start" aria-hidden="true"/);
    expect(BOARD_SCROLLER).toMatch(/className="tasks__edge tasks__edge--end" aria-hidden="true"/);
    const tabIndexes = BOARD_SCROLLER.match(/className="tasks__edge-btn"[^>]*tabIndex=\{-1\}/g) ?? [];
    expect(tabIndexes).toHaveLength(2);
  });

  it("still exposes exactly one scroll region for keyboard and AT users", () => {
    expect(BOARD_SCROLLER).toContain('role="region"');
    expect(BOARD_SCROLLER).toContain('aria-label="Task lists"');
    expect(BOARD_SCROLLER).toContain("tabIndex={0}");
  });

  it("respects reduced motion when paging by chevron", () => {
    expect(BOARD_SCROLLER).toMatch(/prefers-reduced-motion:\s*reduce/);
    expect(BOARD_SCROLLER).toMatch(/behavior:\s*reduce\s*\?\s*"auto"\s*:\s*"smooth"/);
  });
});

describe("overflowEdges", () => {
  it("reports no edges when everything fits", () => {
    expect(overflowEdges({ scrollLeft: 0, scrollWidth: 500, clientWidth: 500 })).toEqual({
      start: false,
      end: false,
    });
  });

  it("reports a start edge once scrolled past the slack", () => {
    expect(overflowEdges({ scrollLeft: 50, scrollWidth: 900, clientWidth: 500 }).start).toBe(true);
  });

  it("reports an end edge while content remains past the viewport", () => {
    expect(overflowEdges({ scrollLeft: 0, scrollWidth: 900, clientWidth: 500 }).end).toBe(true);
  });

  it("clears the end edge once scrolled to the far side", () => {
    expect(overflowEdges({ scrollLeft: 400, scrollWidth: 900, clientWidth: 500 }).end).toBe(false);
  });
});

describe("task card: controls collapse into one row", () => {
  it("keeps Block time and Move to… on a single, non-wrapping row", () => {
    const actions = block(CSS, ".task__actions");
    expect(actions).toContain("display: flex");
    expect(actions).toContain("flex-wrap: nowrap");
  });

  it("moved the actions row out from under the drag-grip column so it can use the full width", () => {
    const taskCard = readFileSync(join(HERE, "TaskCard.tsx"), "utf8");
    // task__body closes before task__actions opens, i.e. the actions row is a sibling of the
    // body/grip pair, not nested inside the body column.
    const bodyClose = taskCard.indexOf("</div>", taskCard.indexOf('className="task__body"'));
    const actionsOpen = taskCard.indexOf('className="task__actions"');
    expect(bodyClose).toBeGreaterThan(-1);
    expect(actionsOpen).toBeGreaterThan(bodyClose);
    expect(block(CSS, ".task__actions")).toContain("grid-column: 1 / -1");
  });
});

describe("sidebar nav: hit target reaches the 44px floor", () => {
  it("declares a 44px minimum touch target", () => {
    expect(token(TOKENS, "--touch-min")).toBe("44px");
  });

  it("extends the hit area to the floor even though the visible pill is smaller", () => {
    const navHeight = Number.parseInt(token(TOKENS, "--nav-height"), 10);
    expect(navHeight).toBeLessThan(44);

    const after = block(SIDEBAR_CSS, ".nav::after");
    expect(after).toContain("position: absolute");
    // inset extends the pseudo-element symmetrically past the pill to the touch-min floor.
    expect(after).toMatch(/inset:\s*calc\(\(var\(--nav-height\)\s*-\s*var\(--touch-min\)\)\s*\/\s*2\)\s*0/);

    const nav = block(SIDEBAR_CSS, ".nav");
    expect(nav).toContain("position: relative");
    expect(nav).toContain("min-height: var(--nav-height)");
  });
});
