/*
 * What makes a dialog modal in fact rather than in name: Escape closes it, focus moves into it
 * on open and back to where it came from on close, Tab is held inside it, and the page behind
 * it is `inert` and `aria-hidden`.
 *
 * This lived inside the write desk, the app's first dialog. It moved here when the shortcut
 * overlay became the second, because a second hand-written trap is where the measured failure
 * — focus escaping at stop 24 of 44 onto controls behind the scrim — comes back. Both dialogs
 * run this one, and `WriteDesk.test.tsx` still pins its behaviour.
 */

import { useEffect, useRef, type RefObject } from "react";

interface ModalFocusOptions {
  open: boolean;
  /** The dialog element. Must be focusable itself (`tabIndex={-1}`); it takes focus on open. */
  panelRef: RefObject<HTMLElement>;
  /** Everything behind the dialog, made inert while it is open. */
  backgroundRef: RefObject<HTMLElement>;
  /**
   * Where focus returns on close. Captured by the caller at the moment it opens the dialog,
   * not here: by the time this effect runs, an `autoFocus` inside the dialog has already moved
   * focus, and capturing then would "restore" it to a control that is about to unmount.
   */
  restoreFocusTo: RefObject<Element | null>;
  /**
   * Where to land when `restoreFocusTo` is gone — a sent reply drops its row from the list.
   * Nearest first; the first still in the document takes focus, so it never falls to <body>.
   */
  restoreFallbacks?: RefObject<HTMLElement[]>;
  onClose: () => void;
}

// Everything that is focusable inside the panel, in document order. Queried per keystroke
// rather than cached: the composer grows a Cc/Bcc row and an error region while it is open,
// so a list captured at mount would trap against a stale set.
//
// No visibility filter. Nothing inside a panel is ever hidden with CSS — the composer
// conditionally RENDERS the Cc/Bcc row rather than hiding it, and compose.css carries no
// `display: none` or `visibility: hidden` at all — so a filter would guard a case that
// cannot arise. An `offsetParent` check also reports every element as hidden under jsdom,
// which has no layout, so it would silently empty this list in the tests that prove the
// trap works.
function focusablesIn(panel: HTMLElement | null): HTMLElement[] {
  if (!panel) return [];
  const selector =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
  return Array.from(panel.querySelectorAll<HTMLElement>(selector));
}

export function useModalFocus({
  open,
  panelRef,
  backgroundRef,
  restoreFocusTo,
  restoreFallbacks,
  onClose,
}: ModalFocusOptions) {
  // Focus goes back only on the close itself. The effect also re-runs while closed whenever
  // `onClose` changes identity, and restoring on every one of those would yank focus back to
  // whatever the dialog was last opened from, long after the person had moved on.
  const wasOpen = useRef(false);

  // Tabbing from the panel used to walk straight out into the page behind the scrim. The
  // background is also marked `inert` while the dialog is up, which both removes it from the
  // tab order and hides it from assistive technology. Without that, `aria-modal="true"` would
  // assert an isolation that did not exist: a screen reader could still walk the whole page
  // behind a dialog claiming to be modal.
  useEffect(() => {
    if (!open) {
      if (wasOpen.current) {
        wasOpen.current = false;
        const previous = restoreFocusTo.current;
        if (previous instanceof HTMLElement && previous.isConnected) {
          previous.focus();
        } else {
          const fallback = restoreFallbacks?.current?.find((el) => el.isConnected);
          if (fallback) {
            if (!fallback.hasAttribute("tabindex")) fallback.setAttribute("tabindex", "-1");
            fallback.focus();
          }
        }
      }
      return;
    }
    wasOpen.current = true;

    const background = backgroundRef.current;
    // `inert` is set through the DOM rather than as a JSX prop: React 18 does not recognise it
    // and warns when handed a boolean.
    background?.setAttribute("inert", "");
    background?.setAttribute("aria-hidden", "true");

    panelRef.current?.focus();

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;

      const panel = panelRef.current;
      const focusables = focusablesIn(panel);
      if (focusables.length === 0) {
        // Nothing to land on; keep focus on the panel rather than letting it escape.
        event.preventDefault();
        panel?.focus();
        return;
      }

      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      const active = document.activeElement;

      // The panel itself holds focus on open (tabIndex -1), so the first Tab must enter the
      // list rather than fall through to the page behind.
      if (active === panel) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
        return;
      }
      if (!(active instanceof HTMLElement) || !panel?.contains(active)) {
        event.preventDefault();
        first.focus();
        return;
      }
      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
      background?.removeAttribute("inert");
      background?.removeAttribute("aria-hidden");
    };
    // The refs are stable; `open` and `onClose` are what change what this does.
  }, [open, onClose, panelRef, backgroundRef, restoreFocusTo]);
}
