/*
 * DraftCard — one item waiting on you, in the assistant column on Today.
 *
 * It used to render its own "Review" and "Edit" buttons with no handlers attached: four cards
 * on the default route meant eight dead buttons, and the most confident-looking control in the
 * whole app — a primary-blue Review, first thing a new user reaches for — did nothing at all.
 * No busy state, no error, no navigation. Meanwhile the identical item on Digest and Focus
 * offered a working Reply that opens the composer.
 *
 * So this no longer invents its own actions. It renders the same `replyActions` set through the
 * same `ActionBar` as every other row, which means one definition of what you can do with a
 * message and one place to change it. The capability comes from the write desk, so a grant that
 * cannot send falls back to the Gmail link exactly as it does elsewhere. A bundle is not a
 * message, so it gets `bundleActions` instead (see `draftActions`).
 */

import type { Draft } from "../api/client";
import { useWriteDesk } from "../compose/WriteDesk";
import { ActionBar } from "../surfaces/ActionBar";
import { NO_WRITES, draftActions } from "../surfaces/actions";
import "./draft-card.css";

interface DraftCardProps {
  draft: Draft;
  /**
   * Not the lead card in its column: its primary action renders as a secondary button, so a
   * column of drafts has one filled "Reply" rather than one per card.
   */
  quiet?: boolean;
}

export function DraftCard({ draft, quiet = false }: DraftCardProps) {
  // Null outside a provider — a detached window or a test renders the card with the actions
  // falling back to their Google links rather than throwing.
  const desk = useWriteDesk();
  const capability = desk?.capability ?? NO_WRITES;

  return (
    // A key scope: R and O act on this card while focus is anywhere inside it. `tabIndex={-1}`
    // lets a click on the card's text give it that focus without adding a Tab stop.
    <article
      className={quiet ? "draftcard draftcard--quiet" : "draftcard"}
      aria-label={`Draft: ${draft.title}`}
      data-keyscope
      tabIndex={-1}
    >
      <div className="draftcard__title">{draft.title}</div>
      <p className="draftcard__body">{draft.summary}</p>
      <div className="draftcard__actions">
        {/* By kind: a bundle has nothing to reply to, so it never gets a Reply. */}
        <ActionBar actions={draftActions(draft, capability)} subject={draft.title} density="compact" />
      </div>
    </article>
  );
}
