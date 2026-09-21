/*
 * DEV-ONLY mock engine. This module is imported only under import.meta.env.DEV
 * (see main.tsx), so it is tree-shaken out of the production bundle the signed
 * app ships. It lets `npm run dev` render the full Option A shell without the
 * Swift engine running, by injecting a fake token and answering /api/* with
 * synthetic data that mirrors the approved nav-options.html.
 *
 * Production NEVER uses this: the real per-launch token comes from the host and
 * the real engine answers the same routes.
 */

import type {
  CalendarsResponse,
  CreateEventRequest,
  CreateEventResponse,
  DraftsResponse,
  Health,
  PlannerEvent,
  Preview,
  SendMailRequest,
  WeekResponse,
  SendMailResponse,
  Settings,
  TasksResponse,
} from "../api/client";

const DAY = "2026-09-14";
const TZ = "-07:00"; // PDT on the mock day

function iso(hhmm: string): string {
  return `${DAY}T${hhmm}:00${TZ}`;
}

const queue: PlannerEvent[] = [
  { id: "q1", title: "Example Corp Audit Co-op — interview time", category: "career", kind: "event", start: iso("08:42"), end: null, due: iso("18:00"), location: null },
  { id: "q2", title: "INDG 101 — Assignment 3", category: "school", kind: "deadline", start: iso("23:59"), end: null, due: iso("23:59"), location: null },
  { id: "q3", title: "ECON 251 — Midterm 2 review posted", category: "school", kind: "event", start: iso("14:30"), end: null, due: null, location: null },
  { id: "q4", title: "Example Consulting coffee chat — reschedule ask", category: "career", kind: "event", start: iso("09:15"), end: null, due: null, location: null },
  { id: "q5", title: "Investment Club — pitch night sign-up", category: "personal", kind: "extracurricular", start: iso("17:00"), end: null, due: null, location: null },
];

const schedule: PlannerEvent[] = [
  { id: "s1", title: "ECON 251 Lecture", category: "school", kind: "event", start: iso("09:00"), end: iso("10:20"), due: null, location: "AQ 3150" },
  { id: "s2", title: "Focus — Assignment 3", category: "school", kind: "deadline", start: iso("11:00"), end: iso("12:00"), due: null, location: null },
  { id: "s3", title: "Coffee chat — Example Consulting", category: "career", kind: "event", start: iso("13:30"), end: iso("14:15"), due: null, location: "Nemesis Coffee" },
  { id: "s4", title: "Investment Club", category: "personal", kind: "extracurricular", start: iso("15:00"), end: iso("16:00"), due: null, location: "SUB 2270" },
];

const preview: Preview = { queue, schedule, day: DAY };

/*
 * `/api/week` — the route this mock forgot.
 *
 * The engine serves ten routes and this table implemented nine. `client.ts` calls
 * `/api/week`, so in dev the request fell through to the real fetch, hit the Vite proxy,
 * and 500'd twice on every page load. Two things followed: the Digest's "week ahead"
 * section could only ever be seen in its error state, and the Calendar's week and month
 * grids — which now read this route — had no data to draw in dev at all.
 *
 * Spread across the days either side of the mock day, so a week grid has something to
 * render in every column rather than one full day and six empty ones.
 */
function shifted(events: PlannerEvent[], dayOffset: number, idSuffix: string): PlannerEvent[] {
  const shiftDay = (value: string | null): string | null => {
    if (!value) return null;
    const d = new Date(value);
    d.setDate(d.getDate() + dayOffset);
    return d.toISOString();
  };
  return events.map((e) => ({
    ...e,
    id: `${e.id}-${idSuffix}`,
    start: shiftDay(e.start) ?? e.start,
    end: shiftDay(e.end),
    due: shiftDay(e.due),
  }));
}

const week: WeekResponse = {
  start: DAY,
  days: 7,
  events: [
    ...schedule,
    ...shifted(schedule, 1, "d1"),
    ...shifted(schedule.slice(0, 2), 2, "d2"),
    ...shifted(schedule.slice(1, 3), 3, "d3"),
    ...shifted(schedule.slice(0, 1), 4, "d4"),
  ],
};

// Shape-matched to the engine on purpose. When this mock and the engine drifted, the UI
// looked correct in `npm run dev` and was broken in the shipped app — that is how the
// __DP_TOKEN__, TaskItem.done and Draft-shape mismatches all survived review.
// d1-d3 are synthetic PROPOSED drafts (no sender). d4 mimics a real inbox thread.
const drafts: DraftsResponse = {
  drafts: [
    { id: "d1", title: "Reply — Example Corp recruiter", summary: "Confirms Thursday 14:30, notes the ECON 251 midterm conflict, proposes Friday 10:00 instead.", kind: "reply" },
    { id: "d2", title: "Calendar + Task bundle", summary: "Creates the Example Consulting chat, a prep task, and a 25-minute transit buffer.", kind: "bundle" },
    { id: "d3", title: "Reply — Example Consulting associate", summary: "Accepts the reschedule, offers two windows that clear your 9–6 rule.", kind: "reply" },
    { id: "d4", title: "ECON 251 — midterm room change", summary: "The Thursday midterm moves to AQ 3150. No action needed unless you had a conflict.", kind: "reply", sender: "registrar@example.test", category: "school", receivedAt: null, threadId: "thread-d4" },
  ],
};

const calendars: CalendarsResponse = {
  calendars: [
    { id: "c1", title: "School", role: "planning" },
    { id: "c2", title: "Career", role: "planning" },
    { id: "c3", title: "Personal", role: "planning" },
  ],
};

const settings: Settings = {
  vaultSelected: true,
  // The engine sends full ISO8601 instants here, not wall-clock strings. This file's whole job
  // is to be shape-identical to the engine, so it sends them too.
  scanTimes: [iso("06:00"), iso("12:00"), iso("21:00")],
  // Dev runs with writes ON, because the composer and the scheduler are the things most worth
  // exercising here and a mock that reports `canSend: false` renders every row in its fallback
  // shape — which is exactly the state that let three contract drifts look correct in dev.
  // Nothing actually leaves: the write routes below are answered by this file.
  safety: {
    mode: "send-and-schedule",
    externalWrites: true,
    label: "Send & schedule · nothing leaves without your confirmation",
  },
  capability: { canSend: true, canSchedule: true },
  // Dev is served by this mock, which is by definition not the user's account.
  source: { kind: "sample", live: false, label: "Sample data · not your account" },
};

const tasks: TasksResponse = {
  lists: [
    { name: "School", items: [
      { id: "t1", title: "Assignment 3", category: "school", due: iso("23:59"), done: false },
      { id: "t2", title: "Midterm 2 review", category: "school", due: null, done: false },
      { id: "t3", title: "Readings — week 3", category: "school", due: null, done: true },
    ]},
    { name: "Career", items: [
      { id: "t4", title: "Prep Example Corp STAR stories", category: "career", due: null, done: false },
      { id: "t5", title: "Thank-you note — Example Consulting", category: "career", due: null, done: false },
    ]},
    { name: "Finance", items: [
      { id: "t6", title: "Reconcile September budget", category: "finance", due: null, done: false },
    ]},
    { name: "Extracurricular", items: [
      { id: "t7", title: "Pitch night slides", category: "personal", due: null, done: false },
      { id: "t8", title: "Book SUB room", category: "personal", due: null, done: false },
    ]},
    { name: "Personal", items: [
      { id: "t9", title: "Groceries", category: "personal", due: null, done: false },
    ]},
  ],
};

const health: Health = { ok: true, mode: "send-and-schedule" };

const ROUTES: Record<string, unknown> = {
  "/api/health": health,
  "/api/preview": preview,
  "/api/week": week,
  "/api/calendars": calendars,
  "/api/settings": settings,
  "/api/drafts": drafts,
  "/api/tasks": tasks,
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function fail(status: number, code: string, message: string): Response {
  return json({ error: { code, message } }, status);
}

/**
 * The write routes, answered locally.
 *
 * These refuse the same things the engine refuses, with the same codes, so the composer's error
 * states can actually be seen in dev instead of only in production against a real account. That
 * is the whole reason this file exists: the shapes the UI meets here must be the shapes it meets
 * in the shipped app.
 */
const WRITES: Record<string, (body: any) => Response> = {
  "/api/mail/send": (body: SendMailRequest) => {
    const to = Array.isArray(body?.to) ? body.to : [];
    if (to.length === 0) return fail(400, "invalid_request", "Check the recipient address.");
    if (to.some((address) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address))) {
      return fail(400, "invalid_request", "Check the recipient address.");
    }
    if (!body?.subject?.trim()) return fail(400, "invalid_request", "Add a subject.");
    if (!body?.body?.trim()) return fail(400, "invalid_request", "Write a message first.");
    const response: SendMailResponse = {
      ok: true,
      id: `mock-${Date.now()}`,
      threadId: body.threadId ?? null,
    };
    // eslint-disable-next-line no-console
    console.info("[dev] mock send — nothing left this machine", { to: body.to, subject: body.subject });
    return json(response);
  },
  "/api/calendar/events": (body: CreateEventRequest) => {
    if (!body?.title?.trim()) return fail(400, "invalid_request", "Give the event a title.");
    const start = new Date(body?.start ?? "");
    const end = new Date(body?.end ?? "");
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
      return fail(400, "invalid_request", "Check the start and end times.");
    }
    if (end <= start) return fail(400, "invalid_request", "The end time has to be after the start time.");
    const response: CreateEventResponse = {
      ok: true,
      id: `mock-evt-${Date.now()}`,
      start: body.start,
      end: body.end,
      htmlLink: null,
    };
    // eslint-disable-next-line no-console
    console.info("[dev] mock event — nothing left this machine", { title: body.title });
    return json(response);
  },
};

export function installMockEngine() {
  window.__DP_TOKEN__ = "dev-mock-token";
  const realFetch = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.pathname : input.url;
    const path = url.startsWith("http") ? new URL(url).pathname : url;
    const known = path in ROUTES || path in WRITES;
    if (!known) return realFetch(input, init);

    const auth = new Headers(init?.headers).get("Authorization");
    if (auth !== `Bearer ${window.__DP_TOKEN__}`) {
      return fail(401, "unauthorized", "Missing token.");
    }

    if ((init?.method ?? "GET").toUpperCase() === "POST") {
      const handler = WRITES[path];
      if (!handler) return fail(405, "method_not_allowed", "Method not allowed.");
      // The engine refuses anything but JSON on a write; so does this, or the client's own
      // content type could be wrong and dev would never notice.
      if (new Headers(init?.headers).get("Content-Type") !== "application/json") {
        return fail(415, "invalid_request", "Expected JSON.");
      }
      try {
        return handler(JSON.parse(String(init?.body ?? "")));
      } catch {
        return fail(400, "invalid_request", "That message could not be read.");
      }
    }

    if (path in WRITES) return fail(405, "method_not_allowed", "Method not allowed.");
    return json(ROUTES[path]);
  };
  // eslint-disable-next-line no-console
  console.info("[dev] mock engine installed — synthetic data, no real network");
}
