/*
 * What the prep card remembers for the rest of this session, and nothing longer.
 *
 * Module state rather than component state, on purpose. A send from the composer calls the
 * shell's `reload()`, which puts Today back into its loading state and unmounts every column —
 * so a thank-you "sent" flag held in React state would be forgotten by the very reload the send
 * triggers, and the "Thank-you due" row would come straight back. A module lives as long as
 * the page does, which is exactly "this session".
 *
 * Remembering a sent thank-you ACROSS launches needs an engine-side store (the P5 waiting-on
 * work). That is out of scope here, and the card's copy never promises it.
 */

import { useSyncExternalStore } from "react";

interface PrepSession {
  /** The event whose card is open on Today, when he picked one. Null → the card picks. */
  selectedId: string | null;
  /** Events thanked from the card this session. */
  thanked: ReadonlySet<string>;
}

let state: PrepSession = { selectedId: null, thanked: new Set() };
const listeners = new Set<() => void>();

function set(next: PrepSession) {
  state = next;
  listeners.forEach((l) => l());
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function usePrepSession(): PrepSession {
  return useSyncExternalStore(subscribe, () => state, () => state);
}

export function selectPrepEvent(id: string | null) {
  set({ ...state, selectedId: id });
}

export function markThanked(id: string) {
  set({ ...state, thanked: new Set([...state.thanked, id]) });
}

/** Tests only: a fresh session per test, so one test's send cannot hide another's row. */
export function resetPrepSession() {
  set({ selectedId: null, thanked: new Set() });
}
