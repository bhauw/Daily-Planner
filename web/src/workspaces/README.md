# Workspaces — the contract for tasks 04–06

This folder holds the three source workspaces: **Mail** (04), **Calendar** (05), **Tasks** (06).
Task 03 (the shell) owns everything outside this folder. This README is the seam between them.
Read it fully before writing a line — it is specific on purpose so you can follow it blind.

You own exactly one directory each and nothing else:

| Task | Directory                       | Route     |
| ---- | ------------------------------- | --------- |
| 04   | `web/src/workspaces/mail/`      | `/mail`   |
| 05   | `web/src/workspaces/calendar/`  | `/calendar` |
| 06   | `web/src/workspaces/tasks/`     | `/tasks`  |

Do **not** touch `../shell/`, `../components/`, `../lib/`, `../api/`, `../app.tsx`, `contract.ts`,
`../tokens.css`, or another workspace's folder. If you think you need a change there, it means the
contract is wrong — leave a note in your completion write-up rather than editing shared code.

---

## 1. How a workspace mounts

The shell auto-discovers workspaces with `import.meta.glob("./workspaces/*/index.tsx")` (see
`../app.tsx`). There is **no registry to edit** and no route to wire. You mount by creating exactly
one file:

```
web/src/workspaces/<name>/index.tsx
```

`<name>` is `mail` | `calendar` | `tasks`. The moment that file exists and default-exports a
`WorkspaceComponent`, the matching sidebar route stops showing the placeholder and renders you —
both inside the shell (`/<name>`) and detached (`/detach/<name>`). Nothing else is required.

Split your surface into as many additional files as you like inside your folder
(`DraftWorkbench.tsx`, `WeekGrid.tsx`, etc.); only `index.tsx` is the mount point.

## 2. The component you export

`index.tsx` must `export default` a component of type `WorkspaceComponent`, imported from the
contract:

```tsx
// web/src/workspaces/mail/index.tsx
import type { WorkspaceProps } from "../contract";

export default function MailWorkspace({ api, day, detached }: WorkspaceProps) {
  // ...
  return <div className="mail">…</div>;
}
```

### Props you receive (`WorkspaceProps`)

| Prop       | Type      | Meaning                                                                                             |
| ---------- | --------- | -------------------------------------------------------------------------------------------------- |
| `api`      | `Api`     | The typed, token-authenticated client. **Already connected** — the shell only mounts you once the engine answered. Just call `await api.drafts()` etc. |
| `day`      | `string`  | The active planning day, `"YYYY-MM-DD"`, from `/api/preview`. Use it; do not re-derive "today".      |
| `detached` | `boolean` | `true` when you are rendered standalone in your own WKWebView window (no shell chrome around you). When `true`, lay out full-bleed — no assumptions about a sidebar to your left. |

You do **not** receive data as props (except `day`). Fetch what you need through `api` and manage
your own loading / empty / error states with the shared helpers below. The shell has already proven
the engine is reachable, so a failure inside a workspace is a per-call failure, not "not connected".

## 3. Import everything from `../contract` — never reach past it

`contract.ts` is your single import surface. It re-exports every type, the api client, the shared
libs, and every shared component. Import from there so you never accidentally re-declare a colour,
a token, or a primitive:

```tsx
import {
  // types
  type Api, type WorkspaceProps, type PlannerEvent, type Draft, type TaskItem, type TaskList,
  // client
  api, ApiError,
  // libs (colour + time are decided here — do not reimplement)
  presentationFor, colorForCategory, kindLabel,
  formatTime, formatRange, formatLongDay, durationMinutes,
  useAsync,
  // shared components — REUSE these, do not rebuild them
  EventRow, Dayline, DraftCard, Button, CountBadge, Tag,
  ColumnHeader, EmptyState, ConnectionState, PressureBar,
} from "../contract";
```

If something you need is not exported from `contract.ts`, that is a shell gap — flag it in your
completion note. Do not import directly from `../components/*` or `../api/*` to route around it.

## 4. Shared components you MUST reuse (do not re-create)

| Component      | Use it for                                                                                   |
| -------------- | -------------------------------------------------------------------------------------------- |
| `Dayline`      | **The one and only timeline.** Calendar (05) and Tasks (06) time-blocking reuse this — never draw a second dayline. It already renders the mono time gutter, category-coloured blocks, flexible markers, free slots, and the `PressureBar`. Pass it `events: PlannerEvent[]` (+ optional `windowStart`/`windowEnd` in minutes-from-midnight). |
| `EventRow`     | One `PlannerEvent` as a list row (queue/list rows). Category chip + tag + mono time are built in. |
| `DraftCard`    | One draft summary card. Mail's workbench builds *on top of* this shape; keep the visual language. |
| `PressureBar`  | The workload meter. It is already inside `Dayline`; only mount it standalone if you have a separate magnitude to show, and **only after reading the `dataviz` skill** (it is a meter). |
| `ColumnHeader` | Eyebrow + title + mono count at the top of any column/pane. Keeps headers identical to the shell. |
| `EmptyState`   | Every empty surface. Never a dead end — give a title + directive detail (active voice), optional action. |
| `ConnectionState` | Only for the detached edge case where your own fetch reports `not_connected`; the shell handles it otherwise. |
| `Button`, `CountBadge`, `Tag` | All buttons, count badges, and category tags. Real `<button>`s with accessible names. |

## 5. Colour rule — a workspace NEVER declares a colour

- Category colour comes **only** from `presentationFor(event)` / `colorForCategory(category)`
  (from the contract). They return a `var(--cat-*)` string — bind it inline
  (`style={{ borderColor: p.colorVar }}`) or apply the class the shared component already uses.
- In your CSS, use only the **semantic** and **component** tokens from `tokens.css`
  (`var(--surface)`, `var(--text-2)`, `var(--space-6)`, `var(--radius-md)`, …).
- **Never** write a raw hex, an `rgb()/hsl()` literal, or a `--p-*` primitive in a workspace.
- `finance` is **lavender** (`--cat-finance`), not career yellow. This is already handled by
  `presentationFor`; do not "correct" it back.
- `SF Mono` (`.num`) is reserved for **times, counts and numerics** so gutters align — never prose.

## 6. Accessibility floor — enforced, non-negotiable

- Real `<button>` / `<a>` for every action. **No clickable `<div>`.** Icon-only controls get an
  accessible name (`aria-label` or `.sr-only` text).
- Everything reachable and operable by keyboard; the global `:focus-visible` ring (see `base.css`)
  must remain visible — do not set `outline: none` without an equal replacement.
- Interactive targets ≥ **44×44px** (`--touch-min`). Text contrast ≥ **4.5:1** — small text uses
  `--text-2` (5.8:1 on `--bg`), never `--text-3` (3.3:1, decorative/large only).
- Respect `prefers-reduced-motion` (handled globally in `base.css`: movement — transforms, size, position, keyframes — is removed, short colour/opacity/shadow transitions stay; don't fight it).
- Drag interactions (Calendar drag-to-propose, Tasks time-blocking) need a keyboard-operable
  equivalent and must announce state — a drag is a *proposal*, never a committed change this round.

## 7. Safety boundary — this round is read-only

- **Nothing sends. Nothing writes externally.** No provider mutation, no notification, no scheduler.
  A "propose" / "approve" / "reject" control changes local UI state only.
- Never put provider content, file paths, tokens, or the excluded-calendar identity in a log line
  or an error message. Errors show `ApiError.message` (already safe text); never `console.log` a
  response body.

## 8. Styling conventions (match the shell)

- Co-locate CSS: `Foo.tsx` imports `./foo.css` (kebab-case file, one per component). The cascade is
  `tokens → base → component`, so import your CSS from inside the component, as the shell does.
- Component files `PascalCase.tsx`; the mount file is the lowercase `index.tsx`.
- Density is a dashboard: use the `--space-*` scale and the `--text-*` scale — no ad-hoc pixels.
- When `detached`, render full-bleed (the shell wraps you in a `DetachedFrame` with only the
  SafetyRail on top); when not, you sit in `main.app__surface` to the right of the sidebar.

## 9. Verify before you hand off

```bash
cd web && npm run build     # must pass with no TypeScript errors
npm run dev                 # your route renders with synthetic data (dev mock engine)
```

`npm run dev` injects a synthetic token and answers `/api/*` from `src/dev/mock.ts`, so you can
build the whole surface without the Swift engine. Confirm your route works both at `/<name>` (in
the shell) and at `/detach/<name>` (standalone) before you call it done.
