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
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { api as defaultApi, type Assist, type Capability } from "../api/client";
import { useModalFocus } from "../lib/useModalFocus";
import { Composer } from "./Composer";
import { Scheduler } from "./Scheduler";
import type { ComposePrefill, SchedulePrefill, Written } from "./types";
import "./compose.css";

export interface WriteDesk {
  /** What the connected grant actually permits. Rows render off this, never off a guess. */
  capability: Capability;
  /**
   * `onSent` fires once, after THIS message is actually away — never on open, never on a
   * failed send. The prep card uses it to drop its "Thank-you due" row; a caller that does not
   * care passes nothing and nothing changes.
   */
  compose: (prefill: ComposePrefill, options?: { onSent?: () => void }) => void;
  schedule: (prefill: SchedulePrefill) => void;
}

const WriteDeskContext = createContext<WriteDesk | null>(null);

export function useWriteDesk(): WriteDesk | null {
  return useContext(WriteDeskContext);
}

type Desk =
  | { kind: "compose"; prefill: ComposePrefill; onSent?: () => void }
  | { kind: "schedule"; prefill: SchedulePrefill };

interface WriteDeskProviderProps {
  capability: Capability;
  /** Injected for tests; the real engine client by default. */
  client?: Pick<typeof defaultApi, "sendMail" | "createEvent" | "moveEvent" | "draftReply"> &
    // Optional so an injected test client need not implement it; without it the composer simply
    // offers no "Offer times".
    Partial<Pick<typeof defaultApi, "week">>;
  /** The assistant, for the composer's offer and for the line that says where content goes. */
  assist?: Assist;
  /** Called after a successful write, so the surfaces can pick the change up. */
  onWrote?: (written: Written) => void;
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
  const restoreAncestors = useRef<HTMLElement[]>([]);
  const remember = () => {
    restoreFocusTo.current = document.activeElement;
    const chain: HTMLElement[] = [];
    for (let el = document.activeElement?.parentElement ?? null; el && el !== document.body; el = el.parentElement) {
      chain.push(el);
    }
    restoreAncestors.current = chain;
  };

  // Set by the composer while it is open: asks before a written reply is thrown away.
  const closeGuard = useRef<(() => boolean) | null>(null);
  const registerCloseGuard = useCallback((guard: (() => boolean) | null) => {
    closeGuard.current = guard;
  }, []);

  /** Closes, whatever is in the form. What the composer's own Discard button calls. */
  const forceClose = useCallback(() => {
    // Never over a send in flight. The request would complete anyway, and the user would be left
    // without the one thing they need: whether it went.
    if (busy) return;
    setOpen(null);
  }, [busy]);

  /** Escape and the backdrop: close only if that loses nothing, or once the user says so. */
  const close = useCallback(() => {
    if (busy) return;
    if (closeGuard.current && !closeGuard.current()) return;
    setOpen(null);
  }, [busy]);

  const value = useMemo<WriteDesk>(
    () => ({
      capability,
      compose: (prefill, options) => {
        remember();
        setOpen({ kind: "compose", prefill, onSent: options?.onSent });
      },
      schedule: (prefill) => {
        remember();
        setOpen({ kind: "schedule", prefill });
      },
    }),
    [capability],
  );

  // Escape closes, focus moves into the panel on open and back to the row on close, Tab is held
  // inside the dialog, and the app behind it is inert. See `useModalFocus` for why each of
  // those is there; the shortcut overlay runs the same hook, so there is one trap to get right.
  useModalFocus({ open: open !== null, panelRef, backgroundRef, restoreFocusTo, restoreFallbacks: restoreAncestors, onClose: close });

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
                      ...(client.week ? { readWeek: client.week } : {}),
                    }
                  : {})}
                onClose={forceClose}
                registerCloseGuard={registerCloseGuard}
                onBusyChange={setBusy}
                onWrote={(written) => {
                  open.onSent?.();
                  onWrote?.(written);
                }}
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
