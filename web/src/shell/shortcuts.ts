/*
 * Every keyboard shortcut in the app, in one list.
 *
 * The app used to print key hints it did not honour: an "R" beside every Reply, an "O" beside
 * every Find in Gmail, an "S" beside every Move it — and not one listener behind any of them.
 * A hint with no key behind it is worse than no hint at all: it teaches the person to press a
 * key, the key does nothing, and from then on they stop trusting every other hint on the screen.
 *
 * So the hints, the listeners and the "?" overlay all read from here. A row's action takes its
 * key from `ROW_KEY`; the rail's number keys are derived from `NAV` order; the overlay renders
 * `SHORTCUTS` verbatim. Add a key anywhere else and the tests in `shortcuts.test.ts` fail, which
 * is the point: two lists of shortcuts is how the hints and the behaviour drifted apart.
 *
 * The rules every listener shares live here too (`shouldIgnoreKey`), because the rule that
 * matters most — a letter typed into a reply is a letter, not a command — is exactly the kind
 * that gets re-implemented slightly differently in each place until one of them is wrong.
 *
 * Nothing on this list sends. A key can OPEN the composer or the scheduler; leaving the machine
 * still goes through their review step and the button on it.
 */

import { NAV, type RouteId } from "./nav";

/** Where a shortcut applies. Drives the overlay's grouping and nothing else. */
export type ShortcutScope = "anywhere" | "row" | "mail" | "tasks" | "calendar" | "dialog";

export interface Shortcut {
  id: string;
  /** What to press, as shown. Several entries mean "any of these". */
  keys: readonly string[];
  /** What it does, in the words the overlay shows. */
  does: string;
  scope: ShortcutScope;
}

/** Headings for the overlay, in the order it shows them. */
export const SCOPE_TITLE: Record<ShortcutScope, string> = {
  anywhere: "Anywhere",
  row: "On the open row or card you are on",
  mail: "Mail",
  tasks: "Tasks",
  calendar: "Calendar",
  dialog: "In a dialog",
};

/**
 * The single-key verbs on a row's action bar, after the mail clients people already know.
 *
 * `ItemAction.shortcut` takes its value from here — see `actions.ts`. There is deliberately no
 * key for "done" or "send": nothing on a row completes or sends by itself.
 */
export const ROW_KEY = {
  reply: "r",
  schedule: "s",
  open: "o",
} as const;

export type RowKey = (typeof ROW_KEY)[keyof typeof ROW_KEY];

/** Tasks' quick capture: focuses the capture field. */
export const CAPTURE_KEY = "c";

/** The key that opens the shortcut overlay. */
export const HELP_KEY = "?";

/**
 * Number keys for the rail: 1 is the first row, in the order the rail draws them.
 *
 * Derived rather than listed, so reordering the rail renumbers the keys with it and the digit
 * always matches the position the person can see. Settings has none: it sits apart at the
 * bottom of the rail and holds no surface — it points at the native window.
 */
export const NAV_KEYS: readonly { key: string; route: RouteId; label: string; path: string }[] = NAV.flatMap(
  (section) => section.items,
).map((item, index) => ({ key: String(index + 1), route: item.id, label: item.label, path: item.path }));

export function navKeyFor(route: RouteId): string | undefined {
  return NAV_KEYS.find((k) => k.route === route)?.key;
}

export const SHORTCUTS: readonly Shortcut[] = [
  { id: "help", keys: [HELP_KEY], does: "Show these shortcuts", scope: "anywhere" },
  {
    id: "nav",
    keys: [`${NAV_KEYS[0].key}–${NAV_KEYS[NAV_KEYS.length - 1].key}`],
    does: `Go to ${NAV_KEYS.map((k) => k.label).join(", ")}`,
    scope: "anywhere",
  },
  {
    id: "row-reply",
    keys: [ROW_KEY.reply],
    does: "Reply — opens the composer; you review before anything sends",
    scope: "row",
  },
  {
    id: "row-schedule",
    keys: [ROW_KEY.schedule],
    does: "Move it, or put it on the day — opens the scheduler to confirm",
    scope: "row",
  },
  { id: "row-open", keys: [ROW_KEY.open], does: "Open it in Gmail, Calendar or Tasks", scope: "row" },
  { id: "mail-next", keys: ["j", "↓"], does: "Next thread", scope: "mail" },
  { id: "mail-prev", keys: ["k", "↑"], does: "Previous thread", scope: "mail" },
  { id: "mail-ends", keys: ["Home", "End"], does: "First or last thread", scope: "mail" },
  { id: "tasks-capture", keys: [CAPTURE_KEY], does: "Capture a task", scope: "tasks" },
  { id: "calendar-shift", keys: ["↑", "↓"], does: "Shift the focused movable block 15 minutes", scope: "calendar" },
  { id: "dialog-review", keys: ["⌘↵"], does: "Go to review from the message body — never straight to send", scope: "dialog" },
  { id: "dialog-close", keys: ["Esc"], does: "Close the dialog", scope: "dialog" },
];

/** The overlay's sections, in `SCOPE_TITLE` order, empty ones dropped. */
export function shortcutGroups(): { scope: ShortcutScope; title: string; items: Shortcut[] }[] {
  return (Object.keys(SCOPE_TITLE) as ShortcutScope[])
    .map((scope) => ({ scope, title: SCOPE_TITLE[scope], items: SHORTCUTS.filter((s) => s.scope === scope) }))
    .filter((g) => g.items.length > 0);
}

/**
 * True when the element is somewhere a key is text rather than a command.
 *
 * Every <input> counts, not just text ones: a focused checkbox is one Space away from being
 * toggled, and "r" landing on it as Reply would be a surprise with no upside.
 */
export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable === true;
}

/**
 * The rule every single-key listener applies before looking at the key.
 *
 * - Typing in a field: the key is a letter.
 * - ⌘, Ctrl or ⌥ held: the key belongs to the system or the browser (⌘R reloads, ⌘O opens).
 *   Shift is allowed, because "?" is a shifted key and "R" should work as well as "r".
 * - Already handled: a component that consumed the key (the thread list's j/k) gets it alone.
 * - A modal is up: the page behind it is inert, and a key must not act on what cannot be seen.
 */
export function shouldIgnoreKey(event: KeyboardEvent): boolean {
  if (event.defaultPrevented) return true;
  if (event.metaKey || event.ctrlKey || event.altKey) return true;
  if (event.isComposing) return true;
  if (isTypingTarget(event.target) || isTypingTarget(document.activeElement)) return true;
  return document.querySelector('[aria-modal="true"]') !== null;
}

/**
 * How a key is printed, in a hint or in the overlay. Letters are shown in capitals, as they
 * are on the keycap; everything else ("?", "Esc", "⌘↵") as written.
 */
export function keyLabel(key: string): string {
  return /^[a-z]$/.test(key) ? key.toUpperCase() : key;
}

/** Whether the event is this key, ignoring case so Shift+R is still R. */
export function isKey(event: KeyboardEvent, key: string): boolean {
  return event.key.length === 1 ? event.key.toLowerCase() === key.toLowerCase() : event.key === key;
}
