/*
 * DraftWorkbench — the Mail workspace: every pending draft in one place, edited
 * side by side, with an honest disclosure of the context that went into each and
 * approve / edit / reject controls.
 *
 * Three panes inside the shell: thread list · draft editor · context. The
 * workbench owns the per-draft action state (the state machine in machine.ts);
 * the panes are presentational. This round is READ-ONLY — approve/reject move
 * local state only and no write endpoint is called (the client has none).
 *
 * ONLY THE THREAD LIST SCROLLS. The editor and context panes are fixed-height
 * flex columns: when all three scrolled, reviewing a draft slid the status
 * stepper, the recipients and the Approve/Reject buttons off the top and bottom
 * of the screen — the three things the review step exists to keep in front of
 * you. The body textarea is the one elastic element and scrolls its own text.
 */

import { useEffect, useMemo, useState } from "react";
import {
  ColumnHeader,
  ConnectionState,
  EmptyState,
  useAsync,
  api as defaultApi,
} from "../contract";
import type { Api, Draft, ReplyIntent } from "../contract";
import { ThreadList, type ThreadRow } from "./ThreadList";
import { DraftEditor } from "./DraftEditor";
import { ContextUsed } from "./ContextUsed";
import { detailFor, isSendAction, type DraftDetail } from "./data";
import {
  approve,
  editBody,
  editSubject,
  initialState,
  preflight,
  reject,
  statusLabel,
  type DraftState,
} from "./machine";
import "./mail.css";

// Synthetic display ages for the thread list (read-only round).
const AGES: Record<string, string> = { d1: "2h", d2: "5h", d3: "1d" };
function ageFor(id: string, i: number): string {
  return AGES[id] ?? `${i + 1}d`;
}

interface WorkItem {
  draft: Draft;
  detail: DraftDetail;
}

export function DraftWorkbench({ api = defaultApi, detached }: { api?: Api; detached: boolean }) {
  const { status, data, reload } = useAsync(async () => (await api.drafts()).drafts);

  if (status === "disconnected") return <ConnectionState onRetry={reload} />;
  if (status === "loading") {
    return (
      <div className="mail__loading" role="status" aria-live="polite">
        Loading drafts…
      </div>
    );
  }
  if (status === "error" || !data) {
    return (
      <EmptyState
        title="Couldn't load drafts"
        detail="The engine returned an unexpected response. Try again in a moment."
        action={
          <button type="button" className="btn btn--default btn--sm" onClick={reload}>
            Try again
          </button>
        }
      />
    );
  }
  if (data.length === 0) {
    return (
      <EmptyState
        title="No drafts waiting"
        detail="When the assistant prepares a reply or a calendar bundle, it will wait here for your review before anything is ever sent."
      />
    );
  }

  return <Loaded drafts={data} detached={detached} api={api} />;
}

function Loaded({
  drafts,
  detached,
  api,
}: {
  drafts: Draft[];
  detached: boolean;
  api: Api;
}) {
  /*
   * Ask the engine for a proposal.
   *
   * The engine re-reads the message from its own copy — the client sends an id and an intent,
   * never content — so the private-message rule holds against Gmail's classification rather
   * than against anything this component claims.
   */
  async function onDraft(messageId: string, intent: ReplyIntent, instruction?: string) {
    const proposal = await api.draftReply({ messageId, intent, instruction });
    return proposal.body;
  }

  const items = useMemo<WorkItem[]>(
    () => drafts.map((draft) => ({ draft, detail: detailFor(draft) })),
    [drafts],
  );

  const [selectedId, setSelectedId] = useState<string>(items[0].draft.id);
  const [states, setStates] = useState<Record<string, DraftState>>(() => {
    const init: Record<string, DraftState> = {};
    for (const it of items) init[it.draft.id] = initialState(it.detail.subject, it.detail.body);
    return init;
  });

  // Keep state keyed to whatever the engine currently returns, without clobbering
  // edits already in flight for drafts that are still present.
  useEffect(() => {
    setStates((prev) => {
      const next: Record<string, DraftState> = {};
      for (const it of items) {
        next[it.draft.id] =
          prev[it.draft.id] ?? initialState(it.detail.subject, it.detail.body);
      }
      return next;
    });
    if (!items.some((it) => it.draft.id === selectedId)) {
      setSelectedId(items[0].draft.id);
    }
  }, [items, selectedId]);

  const selected = items.find((it) => it.draft.id === selectedId) ?? items[0];
  const selectedState = states[selected.draft.id] ?? initialState(selected.detail.subject, selected.detail.body);

  function update(id: string, fn: (s: DraftState) => DraftState) {
    setStates((prev) => ({ ...prev, [id]: fn(prev[id]) }));
  }

  const rows: ThreadRow[] = items.map((it, i) => ({
    draft: it.draft,
    category: it.detail.category,
    status: (states[it.draft.id] ?? initialState(it.detail.subject, it.detail.body)).status,
    age: ageFor(it.draft.id, i),
    replyObligated: isSendAction(it.draft.kind),
  }));

  const pending = rows.filter((r) => r.status !== "rejected").length;

  return (
    <div className={["mail", detached ? "mail--detached" : ""].filter(Boolean).join(" ")}>
      <section className="mail__pane mail__threads-pane scroll-y" aria-label="Pending drafts">
        <ColumnHeader eyebrow="Mail" title="Draft workbench" count={`${pending} waiting`} />
        <div className="mail__hairline" />
        <ThreadList rows={rows} selectedId={selected.draft.id} onSelect={setSelectedId} />
      </section>

      <section className="mail__pane mail__editor-pane" aria-label="Draft editor">
        <ColumnHeader
          eyebrow="Editor"
          title={selected.draft.title}
          count={statusLabel(selectedState.status)}
        />
        <div className="mail__hairline" />
        <DraftEditor
          draft={selected.draft}
          detail={selected.detail}
          state={selectedState}
          onDraft={onDraft}
          onEditSubject={(v) => update(selected.draft.id, (s) => editSubject(s, v))}
          onEditBody={(v) => update(selected.draft.id, (s) => editBody(s, v))}
          onPreflight={() => update(selected.draft.id, preflight)}
          onApprove={() => update(selected.draft.id, approve)}
          onReject={() => update(selected.draft.id, reject)}
        />
      </section>

      <aside className="mail__pane mail__ctx-pane" aria-label="Context used">
        <ColumnHeader eyebrow="Context" title="What was used" />
        <div className="mail__hairline" />
        <ContextUsed context={selected.detail.context} />
      </aside>
    </div>
  );
}
