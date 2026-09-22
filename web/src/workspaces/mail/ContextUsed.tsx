/*
 * ContextUsed — the right pane's honest disclosure of what the assistant drew
 * on to write this draft.
 *
 * SAFETY: counts and categories ONLY. This component is given a `ContextUsedData`
 * whose type cannot carry a note title, a vault path, or a calendar name, so
 * there is nothing here to leak. It states that plainly to the user, too.
 */

import { Tag, inkForCategory } from "../contract";
import type { ContextUsedData } from "./data";

interface ContextUsedProps {
  context: ContextUsedData;
}

function categoryLabel(c: string): string {
  return c[0].toUpperCase() + c.slice(1);
}

export function ContextUsed({ context }: ContextUsedProps) {
  const noteTotal = context.vaultNotes.reduce((n, v) => n + v.count, 0);
  return (
    <div className="ctx">
      <dl className="ctx__list">
        <div className="ctx__row">
          <dt className="ctx__key">Thread messages</dt>
          <dd className="num ctx__val">{context.threadMessages}</dd>
        </div>
        <div className="ctx__row">
          <dt className="ctx__key">Calendar conflicts</dt>
          <dd className="num ctx__val">{context.calendarConflicts}</dd>
        </div>
        <div className="ctx__row">
          <dt className="ctx__key">Vault notes used</dt>
          <dd className="num ctx__val">{noteTotal}</dd>
        </div>
      </dl>

      {context.vaultNotes.length > 0 && (
        <div className="ctx__notes">
          <div className="ctx__notes-head">By category</div>
          <ul className="ctx__notes-list">
            {context.vaultNotes.map((v) => (
              <li key={v.category} className="ctx__note">
                <Tag label={categoryLabel(v.category)} colorVar={inkForCategory(v.category)} />
                <span className="num ctx__note-count">{v.count}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <p className="ctx__safe">
        Counts only. No message text, note titles, or calendar names are shown here — or anywhere in
        this app.
      </p>
    </div>
  );
}
