/*
 * The write desk: the one place in the app where something leaves for Google.
 *
 * Rows across Digest and Focus ask for a composer or a scheduler; this holds
 * the dialog, the capability, and the single call to the engine. Keeping it in
 * one place is what makes "what can this app send" a question with one answer
 * — and it means a row does not need to know how sending works to offer it.
 *
 * Provided through context rather than threaded as props, because ActionBar is
 * three levels below every surface and the alternative is passing two handlers
 * through each of them. `useWriteDesk()` returns null outside a provider, so a
 * detached window or a test renders the same rows with the actions inert.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { api as defaultApi, type Assist, type Capability } from "../api/client";
import { Composer } from "./Composer";
import { Scheduler } from "./Scheduler";
import type { ComposePrefill, SchedulePrefill } from "./types";
import "./compose.css";

export interface WriteDesk {
  /** What the connected grant actually permits. Rows render off this, never off a guess. */
  capability: Capability;
  compose: (prefill: ComposePrefill) => void;
  schedule: (prefill: SchedulePrefill) => void;
}

const WriteDeskContext = createContext<WriteDesk | null>(null);

export function useWriteDesk(): WriteDesk | null {
  return useContext(WriteDeskContext);
}

type Desk =
  | { kind: "compose"; prefill: ComposePrefill }
  | { kind: "schedule"; prefill: SchedulePrefill };

interface WriteDeskProviderProps {
  capability: Capability;
  /** Injected for tests; the real engine client by default. */
  client?: Pick<typeof defaultApi, "sendMail" | "createEvent" | "moveEvent" | "draftReply">;
  /** The assistant, for the composer's offer and for the line that says where content goes. */
  assist?: Assist;
  /** Called after a successful write, so the surfaces can pick the change up. */
  onWrote?: () => void;
  children: ReactNode;
}

export function WriteDeskProvider({
  capability,
  assist,
  client = defaultApi,
  onWrote,
  children,
}: WriteDeskProviderProps) {
  const [open, setOpen] = useState<Desk | null>(null);
  const [busy, setBusy] = useState(false);
  const panelRef = useRef<HTMLDivElement>(null);
  const backgroundRef = useRef<HTMLDivElement>(null);
  const restoreFocusTo = useRef<Element | null>(null);

  const close = useCallback(() => {
    // Never over a send in flight. The request would complete anyway, and the user would be left
    // without the one thing they need: whether it went.
    if (busy) return;
    setOpen(null);
  }, [busy]);

  const value = useMemo<WriteDesk>(
    () => ({
      capability,
      compose: (prefill) => {
        restoreFocusTo.current = document.activeElement;
        setOpen({ kind: "compose", prefill });
      },
      schedule: (prefill) => {
        restoreFocusTo.current = document.activeElement;
        setOpen({ kind: "schedule", prefill });
      },
    }),
    [capability],
  );

  // Everything that is focusable inside the panel, in document order. Queried per keystroke
  // rather than cached: the composer grows a Cc/Bcc row and an error region while it is open,
  // so a list captured at mount would trap against a stale set.
  //
  // No visibility filter. Nothing inside this panel is ever hidden with CSS — the composer
  // conditionally RENDERS the Cc/Bcc row rather than hiding it, and compose.css carries no
  // `display: none` or `visibility: hidden` at all — so a filter would guard a case that
  // cannot arise. An `offsetParent` check also reports every element as hidden under jsdom,
  // which has no layout, so it would silently empty this list in the tests that prove the
  // trap works.
  function focusablesInPanel(): HTMLElement[] {
    const panel = panelRef.current;
    if (!panel) return [];
    const selector =
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    return Array.from(panel.querySelectorAll<HTMLElement>(selector));
  }

  // Escape closes, focus moves into the panel on open and back to the row on close, and Tab
  // is held inside the dialog.
  //
  // It was not held: tabbing from the panel walked straight out into the page behind the
  // scrim — measured at stop 24 of 44, with 21 stops landing on controls the user cannot see
  // and did not mean to reach. The background is also marked `inert` while the dialog is up,
  // which both removes it from the tab order and hides it from assistive technology. Without
  // that, `aria-modal="true"` was asserting an isolation that did not exist: a screen reader
  // could still walk the whole day behind a dialog claiming to be modal.
  useEffect(() => {
    if (!open) {
      const previous = restoreFocusTo.current;
      if (previous instanceof HTMLElement) previous.focus();
      return;
    }

    const background = backgroundRef.current;
    // `inert` is set through the DOM rather than as a JSX prop: React 18 does not recognise it
    // and warns when handed a boolean.
    background?.setAttribute("inert", "");
    background?.setAttribute("aria-hidden", "true");

    panelRef.current?.focus();

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
        return;
      }
      if (event.key !== "Tab") return;

      const focusables = focusablesInPanel();
      if (focusables.length === 0) {
        // Nothing to land on; keep focus on the panel rather than letting it escape.
        event.preventDefault();
        panelRef.current?.focus();
        return;
      }

      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      const active = document.activeElement;

      // The panel itself holds focus on open (tabIndex -1), so the first Tab must enter the
      // list rather than fall through to the page behind.
      if (active === panelRef.current) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
        return;
      }
      if (!(active instanceof HTMLElement) || !panelRef.current?.contains(active)) {
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
  }, [open, close]);

  return (
    <WriteDeskContext.Provider value={value}>
      {/*
       * Wrapper exists so the whole app behind the dialog can be made `inert` in one move.
       * `display: contents` keeps it out of the layout entirely, so the shell's grid is
       * unchanged whether the desk is open or not.
       */}
      <div ref={backgroundRef} style={{ display: "contents" }}>
        {children}
      </div>
      {open && (
        <div
          className="compose__scrim"
          // A click on the backdrop closes, but only a click ON the backdrop: a drag that
          // started inside the form and ended outside it must not throw the draft away.
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) close();
          }}
        >
          <div
            className="compose__panel"
            role="dialog"
            aria-modal="true"
            aria-label={
              open.kind === "compose"
                ? "New message"
                : open.prefill.move
                ? "Move event"
                : "New event"
            }
            tabIndex={-1}
            ref={panelRef}
          >
            {open.kind === "compose" ? (
              <Composer
                prefill={open.prefill}
                send={client.sendMail}
                // Passed only when the engine says an assistant exists. The composer hides the
                // offer without it, rather than showing a button that cannot work.
                {...(assist?.enabled
                  ? {
                      draft: client.draftReply,
                      draftProvider: assist.provider,
                      draftLeavesMachine: assist.contentLeavesMachine,
                    }
                  : {})}
                onClose={close}
                onBusyChange={setBusy}
                onWrote={onWrote}
              />
            ) : (
              <Scheduler
                prefill={open.prefill}
                create={client.createEvent}
                move={client.moveEvent}
                onClose={close}
                onBusyChange={setBusy}
                onWrote={onWrote}
              />
            )}
          </div>
        </div>
      )}
    </WriteDeskContext.Provider>
  );
}
