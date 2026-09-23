/*
 * The registry is the one list of keys. These pin that it IS one list: every key a row
 * advertises is on it, the overlay's entries are unambiguous, and no <kbd> in the source prints
 * a key that did not come from it — which is how "R" and "O" shipped beside buttons with no
 * listener behind them.
 */

// @vitest-environment jsdom
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { Draft, PlannerEvent, TaskItem } from "../api/client";
import { eventActions, replyActions, taskActions, NO_WRITES, type ActionCapability } from "../surfaces/actions";
import { NAV, SETTINGS_ITEM } from "./nav";
import {
  CAPTURE_KEY,
  HELP_KEY,
  NAV_KEYS,
  ROW_KEY,
  SHORTCUTS,
  isKey,
  isTypingTarget,
  keyLabel,
  shortcutGroups,
  shouldIgnoreKey,
} from "./shortcuts";

const CAN_WRITE: ActionCapability = { canSend: true, canSchedule: true, canReschedule: true };

const event: PlannerEvent = {
  id: "e1",
  calendarId: "primary",
  title: "ECONOMICS 295",
  category: "school",
  kind: "event",
  start: "2026-09-16T11:00:00-07:00",
  end: "2026-09-16T12:30:00-07:00",
  due: null,
  location: null,
};
const draft: Draft = { id: "d1", title: "Re: Lease", summary: "", kind: "reply", sender: "a@example.test", receivedAt: null };
const task: TaskItem = { id: "t1", title: "Quiz", category: "school", due: null, done: false };

function keyed(e: Partial<KeyboardEventInit> & { key: string }, target?: HTMLElement): KeyboardEvent {
  const ev = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...e });
  if (target) Object.defineProperty(ev, "target", { value: target });
  return ev;
}

describe("the registry is the one list of keys", () => {
  it("lists every key a row's action advertises, at either capability", () => {
    const listed = new Set(SHORTCUTS.filter((s) => s.scope === "row").flatMap((s) => s.keys));
    for (const capability of [NO_WRITES, CAN_WRITE]) {
      for (const action of [
        ...eventActions(event, capability),
        ...replyActions(draft, capability),
        ...taskActions(task, capability),
      ]) {
        if (action.shortcut) expect(listed.has(action.shortcut), action.id).toBe(true);
      }
    }
  });

  it("has an entry for every row verb, so the overlay never omits one", () => {
    const listed = SHORTCUTS.flatMap((s) => s.keys);
    for (const key of Object.values(ROW_KEY)) expect(listed).toContain(key);
    expect(listed).toContain(HELP_KEY);
    expect(listed).toContain(CAPTURE_KEY);
  });

  it("does not give one key two meanings where both are live at once", () => {
    // Row keys and the global keys are heard on the same surfaces (Today, Focus, Digest).
    const live = SHORTCUTS.filter((s) => s.scope === "anywhere" || s.scope === "row").flatMap((s) => s.keys);
    const all = [...live, ...NAV_KEYS.map((k) => k.key)];
    expect(new Set(all).size).toBe(all.length);
  });

  it("numbers the rail in the order it is drawn, and leaves Settings unnumbered", () => {
    const drawn = NAV.flatMap((s) => s.items).map((i) => i.id);
    expect(NAV_KEYS.map((k) => k.route)).toEqual(drawn);
    expect(NAV_KEYS.map((k) => k.key)).toEqual(drawn.map((_, i) => String(i + 1)));
    expect(NAV_KEYS.some((k) => k.route === SETTINGS_ITEM.id)).toBe(false);
  });

  it("gives every entry a key and words, and ids that do not collide", () => {
    for (const s of SHORTCUTS) {
      expect(s.keys.length).toBeGreaterThan(0);
      expect(s.does.trim().length).toBeGreaterThan(0);
    }
    expect(new Set(SHORTCUTS.map((s) => s.id)).size).toBe(SHORTCUTS.length);
  });

  it("groups the overlay in a fixed order and loses nothing", () => {
    const groups = shortcutGroups();
    expect(groups[0].scope).toBe("anywhere");
    expect(groups.flatMap((g) => g.items)).toHaveLength(SHORTCUTS.length);
  });

  it("prints letters as keycaps and everything else as written", () => {
    expect(keyLabel("r")).toBe("R");
    expect(keyLabel("?")).toBe("?");
    expect(keyLabel("Esc")).toBe("Esc");
  });

  it("prints no <kbd> in the source that does not come from the registry", () => {
    // A literal like <kbd>R</kbd> is exactly the hint that can drift from its listener. Every
    // <kbd> must render `keyLabel(...)` of a registry value, so the hint and the key are one.
    // vitest runs from web/; under jsdom `import.meta.url` is not a file URL to resolve from.
    const root = join(process.cwd(), "src");
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) walk(path);
        else if (path.endsWith(".tsx") && !path.includes(".test.")) files.push(path);
      }
    };
    walk(root);

    const offenders: string[] = [];
    let seen = 0;
    for (const file of files) {
      const source = readFileSync(file, "utf8");
      for (const match of source.matchAll(/<kbd\b[^>]*>([\s\S]*?)<\/kbd>/g)) {
        seen += 1;
        if (!/^\s*\{keyLabel\([^)]*\)\}\s*$/.test(match[1])) offenders.push(`${file}: ${match[0]}`);
      }
    }
    // The hints that exist today (action bar, rail, overlay, capture) — so an empty walk fails.
    expect(seen).toBeGreaterThanOrEqual(4);
    expect(offenders).toEqual([]);
  });
});

describe("keys never fire while typing", () => {
  it("treats inputs, textareas, selects and contenteditable as typing", () => {
    for (const tag of ["input", "textarea", "select"]) {
      expect(isTypingTarget(document.createElement(tag))).toBe(true);
    }
    const editable = document.createElement("div");
    editable.contentEditable = "true";
    // jsdom does not derive isContentEditable from the attribute; state what a browser would.
    Object.defineProperty(editable, "isContentEditable", { value: true });
    expect(isTypingTarget(editable)).toBe(true);
    expect(isTypingTarget(document.createElement("button"))).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
  });

  it("ignores a key typed into a field", () => {
    const input = document.createElement("input");
    expect(shouldIgnoreKey(keyed({ key: "r" }, input))).toBe(true);
    expect(shouldIgnoreKey(keyed({ key: "r" }, document.createElement("button")))).toBe(false);
  });

  it("leaves ⌘, Ctrl and ⌥ combinations to the system, but allows Shift", () => {
    const button = document.createElement("button");
    expect(shouldIgnoreKey(keyed({ key: "r", metaKey: true }, button))).toBe(true);
    expect(shouldIgnoreKey(keyed({ key: "r", ctrlKey: true }, button))).toBe(true);
    expect(shouldIgnoreKey(keyed({ key: "r", altKey: true }, button))).toBe(true);
    expect(shouldIgnoreKey(keyed({ key: "?", shiftKey: true }, button))).toBe(false);
  });

  it("ignores everything while a modal dialog is up", () => {
    const dialog = document.createElement("div");
    dialog.setAttribute("aria-modal", "true");
    document.body.appendChild(dialog);
    expect(shouldIgnoreKey(keyed({ key: "1" }, document.createElement("button")))).toBe(true);
    dialog.remove();
  });

  it("matches a letter whatever its case", () => {
    expect(isKey(keyed({ key: "R", shiftKey: true }), "r")).toBe(true);
    expect(isKey(keyed({ key: "o" }), "r")).toBe(false);
  });
});
