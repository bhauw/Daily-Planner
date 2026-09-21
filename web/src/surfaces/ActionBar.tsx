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
 */

import { useState } from "react";
import { Button } from "../components/Button";
import { useWriteDesk } from "../compose/WriteDesk";
import { isExternalWrite, type ItemAction } from "./actions";
import "./actionbar.css";

interface ActionBarProps {
  actions: ItemAction[];
  /** Name of the thing these act on — used to keep button names unambiguous. */
  subject: string;
  onCompose?: () => void;
  onSchedule?: () => void;
}

export function ActionBar({ actions, subject, onCompose, onSchedule }: ActionBarProps) {
  // Null outside a provider — a detached window or a test renders the same rows with the write
  // actions falling back to their Google links, rather than throwing.
  const desk = useWriteDesk();
  // Transient "Copied" acknowledgement. Silent success leaves the user
  // pressing the button again to see whether it worked the first time.
  const [done, setDone] = useState<string | null>(null);

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
    <div className="actionbar" role="group" aria-label={`Actions for ${subject}`}>
      {actions.map((action) => {
        const blocked = Boolean(action.unavailable);
        return (
          <span key={action.id} className="actionbar__slot">
            <Button
              variant={action.primary && !blocked ? "primary" : "default"}
              size="sm"
              disabled={blocked}
              // The visible label repeats across rows ("Reply" on every message),
              // so the accessible name names the subject too.
              aria-label={`${action.label}: ${subject}`}
              aria-describedby={blocked ? `${action.id}-why` : undefined}
              onClick={() => void run(action)}
            >
              {done === action.id ? "Copied" : action.label}
            </Button>
            {action.shortcut && !blocked && (
              <kbd className="actionbar__key" aria-hidden="true">
                {action.shortcut.toUpperCase()}
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
      {actions.some(isExternalWrite) && (
        <span className="actionbar__note">
          {actions.some((a) => a.compose != null)
            ? "You review the message before it sends."
            : "Nothing is sent or saved without you pressing the button on the screen it opens."}
        </span>
      )}
    </div>
  );
}
