/*
 * Column scaffolding shared by every three-column pane and by workspaces:
 *   - ColumnHeader: eyebrow + title + mono count
 *   - EmptyState:   a calm, directive empty screen (never a dead end)
 *   - ConnectionState: the honest "not connected to the engine" screen
 * These keep every surface visually consistent and keep copy in the app's
 * voice (active verbs, plain nouns, direction not apology).
 */

import type { ReactNode } from "react";
import "./column.css";

interface ColumnHeaderProps {
  eyebrow: string;
  title: string;
  count?: string;
}

export function ColumnHeader({ eyebrow, title, count }: ColumnHeaderProps) {
  return (
    <div className="colhead">
      <div className="colhead__eyebrow">{eyebrow}</div>
      <div className="colhead__row">
        <h3 className="colhead__title">{title}</h3>
        {count && <span className="num colhead__count">{count}</span>}
      </div>
    </div>
  );
}

interface EmptyStateProps {
  icon?: ReactNode;
  title: string;
  detail: string;
  action?: ReactNode;
}

export function EmptyState({ icon, title, detail, action }: EmptyStateProps) {
  return (
    <div className="state" role="status">
      {icon && <div className="state__icon" aria-hidden="true">{icon}</div>}
      <div className="state__title">{title}</div>
      <p className="state__detail">{detail}</p>
      {action && <div className="state__action">{action}</div>}
    </div>
  );
}

interface ConnectionStateProps {
  onRetry?: () => void;
}

export function ConnectionState({ onRetry }: ConnectionStateProps) {
  return (
    <div className="state" role="status">
      <div className="state__icon" aria-hidden="true">
        <PlugIcon />
      </div>
      <div className="state__title">Not connected to the engine</div>
      <p className="state__detail">
        Open Daily Planner from the app to load your day. This window shows real data only when the
        engine is running.
      </p>
      {onRetry && (
        <div className="state__action">
          <button type="button" className="btn btn--default btn--sm" onClick={onRetry}>
            Try again
          </button>
        </div>
      )}
    </div>
  );
}

function PlugIcon() {
  return (
    <svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M9 3v5M15 3v5" strokeLinecap="round" />
      <path d="M6 8h12v3a6 6 0 0 1-12 0V8Z" />
      <path d="M12 17v4" strokeLinecap="round" />
    </svg>
  );
}
