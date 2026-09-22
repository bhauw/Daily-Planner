/*
 * Workspace contract — the single import surface for tasks 04-06.
 *
 * A workspace is a route surface (Mail, Calendar, Tasks) that mounts INSIDE the
 * shell, to the right of the sidebar rail and below the safety rail. Each one
 * lives in its own folder and is discovered automatically — see README.md.
 *
 * Import shared types, the api client, and shared components FROM HERE so the
 * shell owns them and a workspace never re-declares a colour, a token, or a
 * primitive (EventRow, Dayline, DraftCard, Button, Badge, Column bits).
 */

export type {
  Api,
  Category,
  EventKind,
  PlannerEvent,
  Preview,
  WeekResponse,
  CalendarSummary,
  CalendarsResponse,
  Settings,
  Draft,
  DraftsResponse,
  TaskItem,
  TaskList,
  TasksResponse,
  ReplyIntent,
} from "../api/client";
export { api, ApiError } from "../api/client";

export { presentationFor, colorForCategory, inkForCategory, kindLabel } from "../lib/category";
export { formatTime, formatRange, formatLongDay, durationMinutes } from "../lib/format";
export { useAsync } from "../lib/useAsync";
export type { AsyncState, AsyncStatus } from "../lib/useAsync";

export { EventRow } from "../components/EventRow";
export { Dayline } from "../components/Dayline";
export { DraftCard } from "../components/DraftCard";
export { Button } from "../components/Button";
export { CountBadge, Tag } from "../components/Badge";
export { ColumnHeader, EmptyState, ConnectionState } from "../components/Column";
export { PressureBar } from "../components/PressureBar";

import type { Api } from "../api/client";

/**
 * Props every workspace root component receives from the shell.
 * - `api`   : the typed, token-authenticated client (already connected).
 * - `day`   : the active planning day, "YYYY-MM-DD".
 * - `detached`: true when rendered standalone in its own WKWebView window
 *               (no shell chrome around it). Lay out full-bleed when detached.
 */
export interface WorkspaceProps {
  api: Api;
  day: string;
  detached: boolean;
}

/** The type a workspace's `index.tsx` must default-export. */
export type WorkspaceComponent = (props: WorkspaceProps) => JSX.Element;
