/*
 * SidebarRail — the persistent navigation rail (Option A). Plan / Sources /
 * Settings, with pending-count badges and an active state. Every row is a real
 * <a> with an accessible name; the active row is marked aria-current="page".
 * Never a clickable <div>.
 *
 * Each row answers to its number key (1 is the top row; see `NAV_KEYS`), announced through
 * `aria-keyshortcuts` rather than printed, so the rail stays quiet. The "Shortcuts" row at the
 * foot is the visible way into the list of every key, for anyone who has not guessed "?".
 */

import { NAV, SETTINGS_ITEM, type Badges, type NavItem, type RouteId } from "./nav";
import { HELP_KEY, keyLabel, navKeyFor } from "./shortcuts";
import { CountBadge } from "../components/Badge";
import "./sidebar-rail.css";

interface SidebarRailProps {
  active: RouteId;
  badges: Badges;
  onNavigate: (path: string) => void;
  /** Opens the keyboard-shortcut overlay. The row is left out when nothing can show it. */
  onShowShortcuts?: () => void;
}

export function SidebarRail({ active, badges, onNavigate, onShowShortcuts }: SidebarRailProps) {
  return (
    <nav className="sidebar" aria-label="Primary">
      {NAV.map((section) => (
        <div key={section.title} className="sidebar__section">
          <div className="sidebar__sectitle">{section.title}</div>
          {section.items.map((item) => (
            <NavLink
              key={item.id}
              item={item}
              active={item.id === active}
              badge={item.badgeKey ? badges[item.badgeKey] : undefined}
              onNavigate={onNavigate}
            />
          ))}
        </div>
      ))}
      <div className="sidebar__spacer" />
      {onShowShortcuts && (
        <button
          type="button"
          className="nav nav--quiet"
          aria-keyshortcuts={HELP_KEY}
          onClick={onShowShortcuts}
        >
          <span className="nav__label">Shortcuts</span>
          <kbd className="nav__key" aria-hidden="true">
            {keyLabel(HELP_KEY)}
          </kbd>
        </button>
      )}
      <NavLink
        item={SETTINGS_ITEM}
        active={SETTINGS_ITEM.id === active}
        onNavigate={onNavigate}
      />
    </nav>
  );
}

interface NavLinkProps {
  item: NavItem;
  active: boolean;
  badge?: number;
  onNavigate: (path: string) => void;
}

function NavLink({ item, active, badge, onNavigate }: NavLinkProps) {
  const Icon = item.icon;
  const badgeNoun = item.badgeKey === "mail" ? "unread" : "pending";
  return (
    <a
      className={["nav", active ? "nav--on" : ""].filter(Boolean).join(" ")}
      href={item.path}
      aria-current={active ? "page" : undefined}
      aria-keyshortcuts={navKeyFor(item.id)}
      onClick={(e) => {
        // Left-click without a modifier navigates in-app; everything else
        // (cmd-click to open a detached window, etc.) uses the native href.
        if (e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey) {
          e.preventDefault();
          onNavigate(item.path);
        }
      }}
    >
      <Icon />
      <span className="nav__label">{item.label}</span>
      {badge != null && badge > 0 && <CountBadge count={badge} noun={badgeNoun} active={active} />}
    </a>
  );
}
