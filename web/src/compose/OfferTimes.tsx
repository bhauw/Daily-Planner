/*
 * OfferTimes — the slot picker behind the "Offer times" chip.
 *
 * Shared by the two places that draft replies — the Mail workbench's reply box and the composer —
 * for the same reason they share the intent chips: two places that answer "what works for you?"
 * must not disagree about which times are free.
 *
 * What it does, in order: reads the week once, suggests up to five openings from the Calendar's
 * own availability engine (offerSlots.ts), lets him untick any, change the length or the horizon,
 * and hands the ticked ones to `onDraft` as a bounded instruction. That is where it stops. The
 * draft lands in the reply field he was going to edit anyway, and the existing Review → Send step
 * is still the only way anything leaves. Nothing is booked: offering a time is not holding it.
 *
 * INLINE AND FIXED-HEIGHT. In the workbench this sits in the middle pane, which must never scroll
 * (only the thread list does — scroll.test.ts pins it). So the slots are a wrapping row of chips,
 * not a list, and the reasons behind each slot live in its tooltip rather than as extra rows.
 */

import { useId, useMemo, useState } from "react";
import { Button } from "../components/Button";
import type { WeekResponse } from "../api/client";
import { useAsync } from "../lib/useAsync";
import {
  buildOfferInstruction,
  DEFAULT_DURATION,
  DEFAULT_HORIZON,
  OFFER_DURATIONS,
  OFFER_HORIZONS,
  PRECHECKED,
  slotDay,
  slotRange,
  suggestSlots,
} from "./offerSlots";

export interface OfferTimesProps {
  /** Reads the week the slots are found in. Called once when the picker opens. */
  readWeek: () => Promise<WeekResponse>;
  /**
   * Drafts the reply from the instruction. The caller owns the request, the busy state of its
   * other chips and the note that says what happened; the picker only waits for it.
   */
  onDraft: (instruction: string) => Promise<void>;
  onCancel: () => void;
  disabled?: boolean;
}

const slotKey = (s: { dayKey: string; start: number }) => `${s.dayKey}@${s.start}`;

export function OfferTimes({ readWeek, onDraft, onCancel, disabled = false }: OfferTimesProps) {
  const week = useAsync(readWeek);
  // Two pickers can be in the DOM at once (the workbench behind an open composer), so the
  // labelling ids are per instance.
  const id = useId();
  const [duration, setDuration] = useState<number>(DEFAULT_DURATION);
  const [horizon, setHorizon] = useState<number>(DEFAULT_HORIZON);
  // What he flipped away from the default, not what is ticked. A changed length or horizon
  // re-suggests, and the first three of the NEW suggestions should start ticked; a set of ticked
  // slots would silently keep ones that no longer exist.
  const [flipped, setFlipped] = useState<Set<string>>(() => new Set());
  const [writing, setWriting] = useState(false);

  const suggestion = useMemo(
    () =>
      week.data
        ? suggestSlots(week.data.events, { start: week.data.start, days: week.data.days }, duration, horizon)
        : null,
    [week.data, duration, horizon],
  );

  // The first PRECHECKED start ticked; the rest are there to swap in.
  const chosen = useMemo(
    () => (suggestion ? suggestion.slots.filter((s, i) => (i < PRECHECKED) !== flipped.has(slotKey(s))) : []),
    [suggestion, flipped],
  );

  function toggle(key: string) {
    setFlipped((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  async function draft() {
    const built = buildOfferInstruction(chosen, duration);
    if (!built) return;
    setWriting(true);
    try {
      await onDraft(built.instruction);
    } finally {
      setWriting(false);
    }
  }

  const locked = disabled || writing;

  let content;
  if (week.status === "loading") {
    content = (
      <p className="offer__note" role="status">
        Reading your calendar…
      </p>
    );
  } else if (week.status !== "ready" || !suggestion) {
    content = (
      <div className="offer__row">
        <p className="offer__note offer__note--error" role="alert">
          {week.error?.message ?? "Your calendar could not be read."} No times were offered.
        </p>
        <Button type="button" size="sm" variant="default" onClick={week.reload}>
          Try again
        </Button>
      </div>
    );
  } else if (suggestion.slots.length === 0) {
    content = (
      <p className="offer__note" role="status">
        No free {duration}-minute slots in the next {suggestion.searched.length || horizon} business
        days{duration > OFFER_DURATIONS[0] ? " — try a shorter length." : "."}
      </p>
    );
  } else {
    const zone = suggestion.slots[0].zone;
    content = (
      <>
        <div className="offer__slots" role="group" aria-label="Suggested times">
          {suggestion.slots.map((slot) => {
            const key = slotKey(slot);
            const on = chosen.includes(slot);
            return (
              <button
                key={key}
                type="button"
                className={["compose__chip", "offer__slot", on ? "compose__chip--on" : ""].filter(Boolean).join(" ")}
                aria-pressed={on}
                disabled={locked}
                // Why this slot is free. Shown to him only — reasons can name a venue, and they
                // never go into the instruction.
                title={slot.reasons.join(" · ")}
                onClick={() => toggle(key)}
              >
                <span className="offer__day">{slotDay(slot)}</span>{" "}
                <span className="num">{slotRange(slot)}</span>
                {slot.fallback && <span className="offer__tag">evening</span>}
              </button>
            );
          })}
        </div>
        <div className="offer__row">
          <p className="offer__note">
            {zone ? `Pacific time (${zone}). ` : ""}
            {suggestion.clipped
              ? `Your calendar read covers ${suggestion.searched.length} business days, so that is all it checked. `
              : ""}
            Only these times go to the assistant — none of your event names.
          </p>
          <Button
            type="button"
            size="sm"
            variant="primary"
            disabled={locked || chosen.length === 0}
            onClick={() => void draft()}
          >
            {writing ? "Writing…" : chosen.length === 0 ? "Pick a time" : `Draft with ${chosen.length === 1 ? "this time" : "these times"}`}
          </Button>
        </div>
      </>
    );
  }

  return (
    <div className="offer" role="group" aria-label="Offer times">
      <div className="offer__controls">
        <span className="offer__label" id={`${id}-length`}>
          Offer
        </span>
        <div className="offer__seg" role="group" aria-labelledby={`${id}-length`}>
          {OFFER_DURATIONS.map((d) => (
            <button
              key={d}
              type="button"
              className="offer__segbtn"
              aria-pressed={duration === d}
              disabled={locked}
              onClick={() => setDuration(d)}
            >
              {d} min
            </button>
          ))}
        </div>
        <span className="offer__label" id={`${id}-horizon`}>
          in the next
        </span>
        <div className="offer__seg" role="group" aria-labelledby={`${id}-horizon`}>
          {OFFER_HORIZONS.map((n) => (
            <button
              key={n}
              type="button"
              className="offer__segbtn"
              aria-pressed={horizon === n}
              disabled={locked}
              onClick={() => setHorizon(n)}
            >
              {n}
            </button>
          ))}
        </div>
        <span className="offer__label">business days</span>
        <span className="offer__spacer" />
        <Button type="button" size="sm" variant="ghost" disabled={writing} onClick={onCancel}>
          Close
        </Button>
      </div>
      {content}
    </div>
  );
}
