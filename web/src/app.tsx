/*
 * App — router + shell composition.
 *
 * Routing is intentionally dependency-free: we read window.location.pathname,
 * navigate with history.pushState, and listen for popstate. Detached WKWebView
 * windows simply load a sub-URL directly, so the same code renders standalone.
 *
 * Layout (Option A): a persistent sidebar rail, a safety rail across the top of
 * the content, and one main surface that swaps by route. The assistant dock is
 * part of the Today surface (ThreeColumn), so it persists there.
 *
 * Workspaces (Mail/Calendar/Tasks) are discovered automatically: any
 * ./workspaces/<name>/index.tsx is picked up by import.meta.glob and mounted at
 * /<name>. Until task 04-06 add theirs, the route shows a clear placeholder.
 */

import {
  Suspense,
  lazy,
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ComponentType,
  type ReactNode,
} from "react";
import { SidebarRail } from "./shell/SidebarRail";
import { SafetyRail } from "./shell/SafetyRail";
import { ThreeColumn } from "./shell/ThreeColumn";
import { EmptyState, ConnectionState } from "./components/Column";
import { Focus } from "./surfaces/Focus";
import { Digest } from "./surfaces/Digest";
import { DraftCard } from "./components/DraftCard";
import {
  api,
  type Assist,
  type Capability,
  type Draft,
  type Preview,
  type Safety,
  type Source,
  type TasksResponse,
  type WeekResponse,
} from "./api/client";
import { WriteDeskProvider } from "./compose/WriteDesk";
import { useAsync } from "./lib/useAsync";
import { WORKSPACE_ROUTES, routeForPath, type Badges, type RouteId, type WorkspaceRouteId } from "./shell/nav";
import type { WorkspaceComponent, WorkspaceProps } from "./workspaces/contract";
import "./app.css";

const DAY = "2026-09-14"; // superseded by preview.day once the engine responds

// ---- Workspace auto-discovery -------------------------------------------------
const workspaceModules = import.meta.glob("./workspaces/*/index.tsx");

function workspaceLoader(name: string): (() => Promise<{ default: WorkspaceComponent }>) | null {
  const key = `./workspaces/${name}/index.tsx`;
  const loader = workspaceModules[key];
  if (!loader) return null;
  return loader as () => Promise<{ default: WorkspaceComponent }>;
}

const workspaceCache = new Map<string, ComponentType<WorkspaceProps>>();
function workspaceComponent(name: WorkspaceRouteId): ComponentType<WorkspaceProps> | null {
  if (workspaceCache.has(name)) return workspaceCache.get(name)!;
  const loader = workspaceLoader(name);
  if (!loader) return null;
  const Comp = lazy(loader);
  workspaceCache.set(name, Comp);
  return Comp;
}

// ---- Tiny router --------------------------------------------------------------
function usePathname(): [string, (path: string) => void] {
  const [pathname, setPathname] = useState(() => window.location.pathname);
  useEffect(() => {
    const onPop = () => setPathname(window.location.pathname);
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const navigate = useCallback((path: string) => {
    if (path === window.location.pathname) return;
    window.history.pushState({}, "", path);
    setPathname(path);
  }, []);
  return [pathname, navigate];
}

export function App() {
  const [pathname, navigate] = usePathname();

  // Detached windows load their own URL and render with no shell chrome.
  if (pathname === "/drafts") return <DetachedDrafts />;
  if (pathname.startsWith("/detach/")) {
    const name = pathname.slice("/detach/".length) as WorkspaceRouteId;
    if (WORKSPACE_ROUTES.includes(name)) return <DetachedWorkspace name={name} />;
  }

  return <Shell pathname={pathname} navigate={navigate} />;
}

// ---- The shell ----------------------------------------------------------------
interface ShellData {
  preview: Preview;
  drafts: Draft[];
  /** Promotions and spam the engine withheld from the triage list. */
  hiddenCount: number;
  /** The assistant, and whether using it sends content off this Mac. Null when none. */
  assist: Assist | null;
  tasks: TasksResponse;
  /**
   * Which data the engine is serving. Null when /api/settings could not be read — we then show
   * no badge rather than guessing, because wrongly claiming "your account" is the exact failure
   * this field exists to prevent.
   */
  source: Source | null;
  /**
   * The week ahead. Fetched tolerantly like `source`: the digest's week section is an extra, and
   * failing to read it must never blank the day the user actually came for.
   */
  week: WeekResponse | null;
  /**
   * What the engine says it may do to the outside world. Null when /api/settings could not be
   * read — the rail then shows the read-only wording, because claiming less than is true is
   * recoverable and claiming more is not.
   */
  safety: Safety | null;
  /**
   * What the connected grant permits. Defaults to nothing on a failed read for the same reason:
   * a Send button that the token cannot honour is worse than a missing one.
   */
  capability: Capability;
}

const NO_CAPABILITY: Capability = {
  canSend: false,
  canSchedule: false,
  canReschedule: false,
  canDraft: false,
  canReadBody: false,
  canSummarize: false,
};

function Shell({ pathname, navigate }: { pathname: string; navigate: (p: string) => void }) {
  const route = routeForPath(pathname);
  const { status, data, reload } = useAsync<ShellData>(async () => {
    // settings is fetched tolerantly: the source badge is an indicator, and failing to read it
    // must never blank the user's whole day.
    const [preview, draftsRes, tasks, settings, week] = await Promise.all([
      api.preview(),
      api.drafts(),
      api.tasks(),
      api.settings().catch(() => null),
      api.week().catch(() => null),
    ]);
    return {
      preview,
      drafts: draftsRes.drafts,
      hiddenCount: draftsRes.hiddenCount ?? 0,
      assist: settings?.assist ?? null,
      tasks,
      source: settings?.source ?? null,
      week,
      safety: settings?.safety ?? null,
      capability: settings?.capability ?? NO_CAPABILITY,
    };
  });

  const badges: Badges = useMemo(() => {
    if (!data) return {};
    const openTasks = data.tasks.lists.reduce((n, l) => n + l.items.filter((i) => !i.done).length, 0);
    return { mail: data.drafts.length, tasks: openTasks };
  }, [data]);

  return (
    // The desk wraps the whole shell so any row, at any depth, can open the composer without
    // every surface between here and it having to pass a handler down.
    //
    // `onWrote` reloads: an event the user just created belongs on the day they are looking at,
    // and a surface that still shows the day as it was before the write is telling them their
    // action did not take.
    <WriteDeskProvider
      capability={data?.capability ?? NO_CAPABILITY}
      assist={data?.assist ?? undefined}
      onWrote={reload}
    >
      <div className="app">
        <div className="app__body">
          <SidebarRail active={route} badges={badges} onNavigate={navigate} />
          <div className="app__main">
            <SafetyRail
              lastScan="12:00"
              safety={data?.safety ?? null}
              source={data?.source ?? null}
              assist={data?.assist ?? null}
              onOpenSettings={() => navigate("/settings")}
            />
            <main className="app__surface" aria-label={route}>
              <SurfaceContent route={route} status={status} data={data} reload={reload} />
            </main>
          </div>
        </div>
      </div>
    </WriteDeskProvider>
  );
}

function SurfaceContent({
  route,
  status,
  data,
  reload,
}: {
  route: RouteId;
  status: string;
  data: ShellData | null;
  reload: () => void;
}) {
  if (status === "disconnected") return <ConnectionState onRetry={reload} />;
  if (status === "loading") return <LoadingSurface />;
  if (status === "error" || !data) {
    return (
      <EmptyState
        title="Couldn't load your day"
        detail="The engine returned an unexpected response. Try again in a moment."
        action={
          <button type="button" className="btn btn--default btn--sm" onClick={reload}>
            Try again
          </button>
        }
      />
    );
  }

  switch (route) {
    case "today":
      return <ThreeColumn preview={data.preview} drafts={data.drafts} />;
    case "focus":
      return (
        <Focus
          preview={data.preview}
          tasks={data.tasks}
          drafts={data.drafts}
          capability={data.capability}
        />
      );
    case "digest":
      return (
        <Digest
          preview={data.preview}
          tasks={data.tasks}
          drafts={data.drafts}
          hiddenCount={data.hiddenCount}
          week={data.week}
          capability={data.capability}
        />
      );
    case "settings":
      // Settings genuinely lives in a native window: assigning a calendar role and connecting
      // Google write in-process to the encrypted store and the Keychain, not over HTTP, and the
      // engine has no write routes by design. Saying where it is beats a dead end that reads
      // like the feature is missing.
      return (
        <PlaceholderSurface
          title="Settings"
          detail={
            "Open the Daily Planner menu in the menu bar and choose Settings\u2026 " +
            "Google connection, calendar roles and vault permission are configured there."
          }
        />
      );
    case "mail":
    case "calendar":
    case "tasks":
      return <WorkspaceSurface name={route} day={data.preview.day} />;
  }
}

function WorkspaceSurface({ name, day }: { name: WorkspaceRouteId; day: string }) {
  const Comp = workspaceComponent(name);
  if (!Comp) {
    return (
      <PlaceholderSurface
        title={name[0].toUpperCase() + name.slice(1)}
        detail={`This workspace hasn't been built yet. Add web/src/workspaces/${name}/index.tsx to mount it here.`}
      />
    );
  }
  return (
    <Suspense fallback={<LoadingSurface />}>
      <Comp api={api} day={day} detached={false} />
    </Suspense>
  );
}

function LoadingSurface() {
  return <div className="app__loading" role="status" aria-live="polite">Loading…</div>;
}

function PlaceholderSurface({ title, detail }: { title: string; detail: string }) {
  return <EmptyState title={title} detail={detail} />;
}

// ---- Detached surfaces (no shell chrome) --------------------------------------
function DetachedFrame({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="detached">
      <SafetyRail />
      <main className="detached__surface scroll-y" aria-label={label}>
        {children}
      </main>
    </div>
  );
}

function DetachedDrafts() {
  const { status, data, reload } = useAsync(async () => (await api.drafts()).drafts);
  return (
    <DetachedFrame label="Drafts">
      <div className="detached__head">
        <div className="colhead__eyebrow">Drafts</div>
        <h1 className="detached__title">Waiting for your review</h1>
      </div>
      {status === "disconnected" && <ConnectionState onRetry={reload} />}
      {status === "loading" && <LoadingSurface />}
      {status === "ready" && data && data.length === 0 && (
        <EmptyState title="No drafts waiting" detail="Drafts the assistant prepares will appear here." />
      )}
      {status === "ready" && data && data.length > 0 && (
        <div className="detached__list">
          {data.map((d) => (
            <DraftCard key={d.id} draft={d} />
          ))}
        </div>
      )}
    </DetachedFrame>
  );
}

function DetachedWorkspace({ name }: { name: WorkspaceRouteId }) {
  const Comp = workspaceComponent(name);
  return (
    <DetachedFrame label={name}>
      {Comp ? (
        <Suspense fallback={<LoadingSurface />}>
          <Comp api={api} day={DAY} detached={true} />
        </Suspense>
      ) : (
        <PlaceholderSurface
          title={name[0].toUpperCase() + name.slice(1)}
          detail={`This workspace hasn't been built yet.`}
        />
      )}
    </DetachedFrame>
  );
}
