/*
 * The navigation model. This is the contract the SidebarRail renders and the
 * router resolves. Workspaces (04-06) mount at the "mail" | "calendar" | "tasks"
 * routes; they do not add rail rows.
 */

import type { ComponentType, SVGProps } from "react";
import {
  CalendarIcon,
  DigestIcon,
  FocusIcon,
  MailIcon,
  SettingsIcon,
  TasksIcon,
  TodayIcon,
} from "./icons";

export type RouteId =
  | "today"
  | "focus"
  | "digest"
  | "mail"
  | "calendar"
  | "tasks"
  | "settings";

/** Route ids that a workspace module (04-06) supplies content for. */
export const WORKSPACE_ROUTES = ["mail", "calendar", "tasks"] as const;
export type WorkspaceRouteId = (typeof WORKSPACE_ROUTES)[number];

export interface NavItem {
  id: RouteId;
  label: string;
  path: string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
  /** which pending-count from the badges map to show, if any. */
  badgeKey?: "mail" | "tasks";
}

export interface NavSection {
  title: string;
  items: NavItem[];
}

export const NAV: NavSection[] = [
  {
    title: "Plan",
    items: [
      { id: "today", label: "Today", path: "/", icon: TodayIcon },
      { id: "focus", label: "Focus", path: "/focus", icon: FocusIcon },
      { id: "digest", label: "Digest", path: "/digest", icon: DigestIcon },
    ],
  },
  {
    title: "Sources",
    items: [
      { id: "mail", label: "Mail", path: "/mail", icon: MailIcon, badgeKey: "mail" },
      { id: "calendar", label: "Calendar", path: "/calendar", icon: CalendarIcon },
      { id: "tasks", label: "Tasks", path: "/tasks", icon: TasksIcon, badgeKey: "tasks" },
    ],
  },
];

export const SETTINGS_ITEM: NavItem = {
  id: "settings",
  label: "Settings",
  path: "/settings",
  icon: SettingsIcon,
};

export type Badges = Partial<Record<"mail" | "tasks", number>>;

/** Resolve a pathname to a RouteId. Unknown paths fall back to "today". */
export function routeForPath(pathname: string): RouteId {
  const all = [...NAV.flatMap((s) => s.items), SETTINGS_ITEM];
  const match = all.find((i) => i.path === pathname);
  return match?.id ?? "today";
}
