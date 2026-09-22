/*
 * SafetyRail — the always-visible, honest safety banner. It must never be
 * hidden, and no workspace may override it.
 *
 * Its text used to be fixed at "Read-only · no external writes", which was true
 * for as long as the engine had no write routes. It is not true on a connection
 * that granted send and schedule, so the wording now comes FROM the engine's
 * own safety descriptor rather than from this file. A safety label that is
 * merely reassuring, rather than accurate, is worse than no label at all: this
 * is the line the user reads to know what the app can do with their account.
 *
 * The lock icon follows the same rule — a closed padlock over an app that can
 * send mail is the picture version of the same false claim.
 *
 * Drafting is stated SEPARATELY from writes, because it is a different promise.
 * `safety.mode` answers "what may this app do to my account"; `assist` answers
 * "where does my content go". An app that can send mail but drafts nothing, and
 * one that drafts through a local model but cannot send, are both real
 * configurations, and folding them into one sentence would describe neither.
 */

import { LockIcon, UnlockIcon } from "./icons";
import { Button } from "../components/Button";
import { SettingsIcon } from "./icons";
import type { Assist, Safety, Source } from "../api/client";
import "./safety-rail.css";

/** Shown until /api/settings answers. The cautious claim is the one to make while unsure. */
const UNKNOWN_SAFETY: Safety = {
  mode: "read-only",
  externalWrites: false,
  label: "Read-only · no external writes",
};

interface SafetyRailProps {
  lastScan?: string; // e.g. "12:00" — a time only, never content
  /**
   * What the engine says it may do right now. Null while unknown, which renders the read-only
   * wording — never the permissive one, because claiming less than is true is recoverable and
   * claiming more is not.
   */
  safety?: Safety | null;
  /**
   * Which data the engine is serving. When the Keychain read fails the app falls back to
   * synthetic fixtures — correct, because the app must always open, but it used to be silent,
   * so "Synthetic school task" sat in the same chrome as real mail with nothing to tell them
   * apart. Null means unknown, and we say nothing rather than claim the account is connected.
   */
  source?: Source | null;
  /**
   * The assistant, when one is wired. Its own pill rather than part of the main label: this is
   * the only thing in the app that sends the user's content somewhere that is not Google, and
   * it should not be readable as a footnote to the write mode.
   */
  assist?: Assist | null;
  onOpenSettings?: () => void;
}

export function SafetyRail({
  lastScan,
  safety,
  source,
  assist,
  onOpenSettings,
}: SafetyRailProps) {
  // Keyed off `live`, not `kind`, so an unrecognised future source is treated as not-live.
  const showSampleWarning = source != null && !source.live;
  const state = safety ?? UNKNOWN_SAFETY;
  const writes = state.externalWrites === true;

  return (
    <div
      className={`saferail${writes ? " saferail--writes" : ""}`}
      role="note"
      aria-label={state.label}
    >
      {writes ? (
        <UnlockIcon className="saferail__lock" />
      ) : (
        <LockIcon className="saferail__lock" />
      )}
      <span className="saferail__text">{state.label}</span>
      {showSampleWarning && (
        <span className="saferail__sample" role="status" aria-label={source.label}>
          {source.label}
        </span>
      )}
      {assist?.enabled && (
        <span
          className={`saferail__assist${
            assist.contentLeavesMachine ? " saferail__assist--leaves" : ""
          }`}
          role="status"
          aria-label={assist.label}
        >
          {assist.label}
        </span>
      )}
      <span className="saferail__spacer" />
      {lastScan && (
        <span className="saferail__pill num" aria-label={`Last scan ${lastScan}`}>
          Last scan {lastScan}
        </span>
      )}
      {onOpenSettings && (
        <Button variant="ghost" size="sm" icon={<SettingsIcon />} label="Settings" onClick={onOpenSettings} />
      )}
    </div>
  );
}
