/*
 * The row of actions that appears when you press a row.
 *
 * Every button carries its label. Nothing is hover-only: once the row is open
 * its actions are simply there, which is the difference between an interface
 * you can learn by looking at it and one you have to be told about.
 *
 * An action that cannot run yet is rendered disabled with its reason beside
 * it, rather than hidden. Hiding it would make the capability invisible;
 * showing it live would make the button a lie.
 *
 * The key printed beside a button is live. It acts on the row or card that holds focus — the
 * nearest `[data-keyscope]` ancestor — and on no other: Today shows four cards with an "R"
 * each, and one keypress must answer one message, not four. A row that is folded shut hides
 * its hints, so it ignores its keys too. What a key does is exactly what the button does,
 * through the same `run`, so a key can open the composer but never send; sending is still the
 * review step and the button on it.
 *
 * Scope elements carry `tabIndex={-1}`: WebKit does not focus a button on click, so without a
 * focusable ancestor a click on a card would leave focus on <body> and its keys unreachable.
 */

import { useEffect, useRef, useState } from "react";
import { Button } from "../components/Button";
import { useWriteDesk } from "../compose/WriteDesk";
import { isKey, keyLabel, shouldIgnoreKey } from "../shell/shortcuts";
import { isExternalWrite, type ItemAction } from "./actions";
import "./actionbar.css";

interface ActionBarProps {
  actions: ItemAction[];
  /** Name of the thing these act on — used to keep button names unambiguous. */
  subject: string;
  onCompose?: () => void;
  onSchedule?: () => void;
  /**
   * "compact" is for a narrow card (the Today assistant column): the primary stays filled, the
   * rest drop to ghost buttons, and the shortcut hints move into the tooltip so the whole set
   * fits one row. The actions themselves, and what they do, are identical.
   */
  density?: "default" | "compact";
}

export function ActionBar({ actions, subject, onCompose, onSchedule, density = "default" }: ActionBarProps) {
  const compact = density === "compact";
  // Null outside a provider — a detached window or a test renders the same rows with the write
  // actions falling back to their Google links, rather than throwing.
  const desk = useWriteDesk();
  // Transient "Copied" acknowledgement. Silent success leaves the user
  // pressing the button again to see whether it worked the first time.
  const [done, setDone] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  // The listener is attached once; it reads the current actions and `run` through this, so a
  // re-render (a fresh actions array every time) does not re-subscribe it.
  const latest = useRef({ actions, run });
  latest.current = { actions, run };

  useEffect(() => {
    const root = rootRef.current;
    const scope = root?.closest<HTMLElement>("[data-keyscope]") ?? root;
    if (!root || !scope) return;

    // On the scope rather than the window: keydown bubbles from the focused element, so this
    // only ever hears keys pressed while focus is inside this row — which is the scoping rule.
    function onKey(event: KeyboardEvent) {
      if (shouldIgnoreKey(event)) return;
      if (root!.closest("details:not([open])")) return;
      const action = latest.current.actions.find(
        (a) => a.shortcut && !a.unavailable && isKey(event, a.shortcut),
      );
      if (!action) return;
      event.preventDefault();
      void latest.current.run(action);
    }
    scope.addEventListener("keydown", onKey);
    return () => scope.removeEventListener("keydown", onKey);
  }, []);

  async function run(action: ItemAction) {
    switch (action.effect) {
      case "open":
        if (action.href) window.open(action.href, "_blank", "noopener,noreferrer");
        break;
      case "copy":
        if (action.text) {
          try {
            await navigator.clipboard.writeText(action.text);
            setDone(action.id);
            window.setTimeout(() => setDone((d) => (d === action.id ? null : d)), 1600);
          } catch {
            // A denied clipboard is not worth an error dialog; the row still works.
          }
        }
        break;
      // In-app first: an action built against a grant that can write carries its prefill, and
      // the desk opens on top of the day. The href is what is left when it cannot — an account
      // connected before write scopes existed still gets a row that does something.
      case "compose":
        if (action.compose && desk) desk.compose(action.compose);
        else if (onCompose) onCompose();
        else if (action.href) window.open(action.href, "_blank", "noopener,noreferrer");
        break;
      case "schedule":
        if (action.schedule && desk) desk.schedule(action.schedule);
        else if (onSchedule) onSchedule();
        else if (action.href) window.open(action.href, "_blank", "noopener,noreferrer");
        break;
    }
  }

  return (
    <div
      ref={rootRef}
      className={["actionbar", compact ? "actionbar--compact" : ""].filter(Boolean).join(" ")}
      role="group"
      aria-label={`Actions for ${subject}`}
    >
      {actions.map((action) => {
        const blocked = Boolean(action.unavailable);
        return (
          <span key={action.id} className="actionbar__slot">
            <Button
              variant={action.primary && !blocked ? "primary" : compact ? "ghost" : "default"}
              size="sm"
              disabled={blocked}
              // The visible label repeats across rows ("Reply" on every message),
              // so the accessible name names the subject too.
              aria-label={`${action.label}: ${subject}`}
              aria-describedby={blocked ? `${action.id}-why` : undefined}
              // The hint beside the button is aria-hidden; this is how a screen reader hears it.
              aria-keyshortcuts={action.shortcut && !blocked ? keyLabel(action.shortcut) : undefined}
              title={compact && action.shortcut && !blocked ? `${action.label} (${keyLabel(action.shortcut)})` : undefined}
              onClick={() => void run(action)}
            >
              {done === action.id ? "Copied" : action.label}
            </Button>
            {action.shortcut && !blocked && !compact && (
              <kbd className="actionbar__key" aria-hidden="true">
                {keyLabel(action.shortcut)}
              </kbd>
            )}
            {blocked && (
              <span className="actionbar__why" id={`${action.id}-why`}>
                {action.unavailable}
              </span>
            )}
          </span>
        );
      })}
      {/* Only live writes earn the reassurance; a disabled one opens nothing to review. */}
      {actions.some((a) => isExternalWrite(a) && !a.unavailable) && (
        <span className="actionbar__note">
          {actions.some((a) => a.compose != null)
            ? "You review the message before it sends."
            : "Nothing is sent or saved without you pressing the button on the screen it opens."}
        </span>
      )}
    </div>
  );
}
