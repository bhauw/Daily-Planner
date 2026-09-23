/*
 * The app-wide keys, and the "?" overlay that lists every key in the app.
 *
 * Two jobs, one component, because they share a rule: nothing global fires while a dialog is
 * up or while the person is typing (`shouldIgnoreKey`). The number keys follow the rail — 1 is
 * its first row — and "?" opens a dialog that renders `shortcutGroups()` verbatim, so the list
 * a person reads here is the same list the hints and listeners are built from.
 *
 * The overlay is a real modal: it runs the write desk's focus trap (`useModalFocus`), so Tab
 * stays inside, Esc closes, the page behind is inert, and focus goes back where it was.
 */

import { useCallback, useEffect, useLayoutEffect, useRef, type RefObject } from "react";
import { Button } from "../components/Button";
import { useModalFocus } from "../lib/useModalFocus";
import { HELP_KEY, NAV_KEYS, isKey, keyLabel, shortcutGroups, shouldIgnoreKey } from "./shortcuts";
import "./keyboard-shortcuts.css";

interface KeyboardShortcutsProps {
  /** Controlled, so a visible control (the rail's "Shortcuts" row) can open it as well as "?". */
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onNavigate: (path: string) => void;
  /** The app behind the overlay, made inert while it is open. */
  backgroundRef: RefObject<HTMLElement>;
}

export function KeyboardShortcuts({ open, onOpenChange, onNavigate, backgroundRef }: KeyboardShortcutsProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const restoreFocusTo = useRef<Element | null>(null);

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  const show = useCallback(() => onOpenChange(true), [onOpenChange]);

  // Remember where focus was, for the trap to put it back on close. A layout effect runs
  // before the trap's passive one moves focus into the panel, so this still sees the control
  // (or row) the person was on — whichever way the overlay was opened.
  useLayoutEffect(() => {
    if (open) restoreFocusTo.current = document.activeElement;
  }, [open]);

  useModalFocus({ open, panelRef, backgroundRef, restoreFocusTo, onClose: close });

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (open) {
        // "?" puts away what "?" brought up. Everything else in here is the trap's business.
        if (isKey(event, HELP_KEY) && !event.metaKey && !event.ctrlKey && !event.altKey) {
          event.preventDefault();
          close();
        }
        return;
      }
      if (shouldIgnoreKey(event)) return;
      if (isKey(event, HELP_KEY)) {
        event.preventDefault();
        show();
        return;
      }
      const nav = NAV_KEYS.find((k) => event.key === k.key);
      if (nav) {
        event.preventDefault();
        onNavigate(nav.path);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, close, show, onNavigate]);

  if (!open) return null;

  return (
    <div
      className="keys__scrim"
      // Only a click ON the backdrop closes — the same rule as the write desk's scrim.
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) close();
      }}
    >
      <div
        className="keys__panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="keys-title"
        aria-describedby="keys-lede"
        tabIndex={-1}
        ref={panelRef}
      >
        <div className="keys__head">
          <h2 id="keys-title" className="keys__title">
            Keyboard shortcuts
          </h2>
          <Button size="sm" onClick={close}>
            Close
          </Button>
        </div>
        <p id="keys-lede" className="keys__lede">
          Keys do nothing while you are typing in a field. No key sends: the ones that write open the
          composer or the scheduler, and you confirm there.
        </p>
        {shortcutGroups().map((group) => (
          <section key={group.scope} className="keys__group" aria-labelledby={`keys-${group.scope}`}>
            <h3 id={`keys-${group.scope}`} className="keys__grouptitle">
              {group.title}
            </h3>
            <dl className="keys__list">
              {group.items.map((item) => (
                <div key={item.id} className="keys__row">
                  <dt className="keys__keys">
                    {item.keys.map((key, i) => (
                      <span key={key}>
                        {i > 0 && <span className="keys__or"> or </span>}
                        <kbd className="keys__key">{keyLabel(key)}</kbd>
                      </span>
                    ))}
                  </dt>
                  <dd className="keys__does">{item.does}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>
    </div>
  );
}
