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
  useRef,
  useState,
  type ComponentType,
  type ReactNode,
} from "react";
import { SidebarRail } from "./shell/SidebarRail";
import { SafetyRail } from "./shell/SafetyRail";
import { KeyboardShortcuts } from "./shell/KeyboardShortcuts";
import { ThreeColumn } from "./shell/ThreeColumn";
import { EmptyState, ConnectionState } from "./components/Column";
import { Focus } from "./surfaces/Focus";
import { Digest } from "./surfaces/Digest";
import { Settings } from "./surfaces/Settings";
import { Plan } from "./surfaces/plan/Plan";
import { DraftCard } from "./components/DraftCard";
import { mailBadgeCount } from "./surfaces/mailTriage";
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
import type { Written } from "./compose/types";
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
  /** Today's scan slots. Null when /api/settings could not be read — no time is then shown. */
  scanTimes: string[] | null;
}

const NO_CAPABILITY: Capability = { canSend: false, canSchedule: false, canReschedule: false, canDraft: false, canReadBody: false, canSummarize: false };

function Shell({ pathname, navigate }: { pathname: string; navigate: (p: string) => void }) {
  const route = routeForPath(pathname);
  // The "?" overlay. Held here rather than inside it so the rail's visible "Shortcuts" row can
  // open it too — a key nobody has been told about is only half a feature.
  const [showKeys, setShowKeys] = useState(false);
  const appRef = useRef<HTMLDivElement>(null);
  const { status, data: loaded, reload } = useAsync<ShellData>(async () => {
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
      scanTimes: settings?.scanTimes ?? null,
    };
  });

  /*
   * Messages answered from this app in this session.
   *
   * A sent reply used to stay on every list — dock, Digest, Focus — until something reloaded,
   * and the reload itself unmounted the surface. The item now drops the moment the send lands,
   * and stays dropped across the background re-read: the inbox the engine reads may still hold
   * the thread (answering does not archive it), but it is no longer waiting on you.
   */
  const [answered, setAnswered] = useState<ReadonlySet<string>>(() => new Set());
  const onWrote = useCallback(
    (written: Written) => {
      if (written.kind === "mail" && written.answers) {
        const id = written.answers;
        setAnswered((prev) => new Set(prev).add(id));
      }
      // In the background: status stays ready, so open rows, scroll and focus survive it.
      reload();
    },
    [reload],
  );
  const data = useMemo<ShellData | null>(
    () => (loaded ? { ...loaded, drafts: loaded.drafts.filter((d) => !answered.has(d.id)) } : null),
    [loaded, answered],
  );

  const badges: Badges = useMemo(() => {
    if (!data) return {};
    const openTasks = data.tasks.lists.reduce((n, l) => n + l.items.filter((i) => !i.done).length, 0);
    // Unread messages — the number Digest states — not every dock item, bundles included.
    return { mail: mailBadgeCount(data.drafts), tasks: openTasks };
  }, [data]);

  return (
    // The desk wraps the whole shell so any row, at any depth, can open the composer without
    // every surface between here and it having to pass a handler down.
    //
    // `onWrote` refreshes: an event the user just created belongs on the day they are looking
    // at, and a surface that still shows the day as it was before the write is telling them
    // their action did not take. It refreshes BEHIND the surface (see useAsync), not over it.
    <WriteDeskProvider
      capability={data?.capability ?? NO_CAPABILITY}
      assist={data?.assist ?? undefined}
      onWrote={onWrote}
    >
      <div className="app" ref={appRef}>
        <div className="app__body">
          <SidebarRail
            active={route}
            badges={badges}
            onNavigate={navigate}
            onShowShortcuts={() => setShowKeys(true)}
          />
          <div className="app__main">
            {/* No lastScan: the engine reports no scan time yet, and the rail says "—" rather than a made-up one. */}
            <SafetyRail
              safety={data?.safety ?? null}
              source={data?.source ?? null}
              assist={data?.assist ?? null}
              onOpenSettings={() => navigate("/settings")}
            />
            <main className="app__surface" aria-label={route}>
              <SurfaceContent route={route} status={status} data={data} reload={reload} navigate={navigate} />
            </main>
          </div>
        </div>
      </div>
      {/* Outside `.app`, so the overlay can make the whole app behind it inert and stay live. */}
      <KeyboardShortcuts
        open={showKeys}
        onOpenChange={setShowKeys}
        onNavigate={navigate}
        backgroundRef={appRef}
      />
    </WriteDeskProvider>
  );
}

function SurfaceContent({
  route,
  status,
  data,
  reload,
  navigate,
}: {
  route: RouteId;
  status: string;
  data: ShellData | null;
  reload: () => void;
  navigate: (path: string) => void;
}) {
  // Settings reads its own routes and states its own failures. It is the page someone opens
  // BECAUSE the day won't load, so it must not be hidden behind the day's error screen.
  //
  // Changing a setting still happens natively — Google connection, calendar roles and the vault
  // are written in-process to the Keychain and the encrypted store, never over HTTP — and the
  // surface says so next to each one.
  if (route === "settings") return <Settings />;

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
      return (
        <ThreeColumn
          preview={data.preview}
          drafts={data.drafts}
          weekEvents={data.week?.events ?? null}
          tasks={data.tasks}
          scanTimes={data.scanTimes}
          onPlan={() => navigate("/plan")}
        />
      );
    case "plan":
      // `onWrote` is the shell reload, and the surface calls it only when he leaves: reloading
      // unmounts it, and the per-block outcome of the write must stay readable until then.
      return (
        <Plan
          preview={data.preview}
          tasks={data.tasks}
          drafts={data.drafts}
          capability={data.capability}
          onWrote={reload}
          onDone={() => navigate("/")}
        />
      );
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
          {data.map((d, i) => (
            <DraftCard key={d.id} draft={d} quiet={i > 0} />
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
