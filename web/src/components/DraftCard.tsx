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
 * cannot send falls back to the Gmail link exactly as it does elsewhere.
 */

import type { Draft } from "../api/client";
import { useWriteDesk } from "../compose/WriteDesk";
import { ActionBar } from "../surfaces/ActionBar";
import { NO_WRITES, replyActions } from "../surfaces/actions";
import "./draft-card.css";

interface DraftCardProps {
  draft: Draft;
}

export function DraftCard({ draft }: DraftCardProps) {
  // Null outside a provider — a detached window or a test renders the card with the actions
  // falling back to their Google links rather than throwing.
  const desk = useWriteDesk();
  const capability = desk?.capability ?? NO_WRITES;

  return (
    <article className="draftcard" aria-label={`Draft: ${draft.title}`}>
      <div className="draftcard__title">{draft.title}</div>
      <p className="draftcard__body">{draft.summary}</p>
      <div className="draftcard__actions">
        <ActionBar actions={replyActions(draft, capability)} subject={draft.title} />
      </div>
    </article>
  );
}
