/*
 * Badge — a small numeric count (nav pending counts) or a category tag.
 * Counts render in the mono face with tabular figures. A count includes a
 * screen-reader phrase so "12" is announced as "12 pending".
 */

import "./badge.css";

interface CountBadgeProps {
  count: number;
  /** e.g. "pending", "unread" — completes the accessible phrase. */
  noun?: string;
  active?: boolean;
}

export function CountBadge({ count, noun = "pending", active = false }: CountBadgeProps) {
  if (count <= 0) return null;
  return (
    <span className={["badge", active ? "badge--active" : ""].filter(Boolean).join(" ")}>
      <span className="num" aria-hidden="true">
        {count}
      </span>
      <span className="sr-only">
        {count} {noun}
      </span>
    </span>
  );
}

interface TagProps {
  label: string;
  colorVar: string;
}

export function Tag({ label, colorVar }: TagProps) {
  return (
    <span className="tag" style={{ color: colorVar }}>
      {label}
    </span>
  );
}
