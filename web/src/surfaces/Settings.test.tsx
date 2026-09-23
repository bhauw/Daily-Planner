/*
 * The Settings surface.
 *
 * Pinned: every section renders from engine-shaped data; a write grant and a read-only grant are
 * told apart; a failed settings read is an error state, not a blank page; a failed calendars read
 * is a note, not an error; and — the property the whole surface rests on — nothing it does
 * reaches a write route. It GETs three read routes and nothing else.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ApiError, type Settings as EngineSettings } from "../api/client";
import { Settings, type SettingsData } from "./Settings";

let root: Root | null = null;
let host: HTMLElement | null = null;

afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
  vi.unstubAllGlobals();
  delete window.__DP_TOKEN__;
});

// Shape-matched to the dev mock and the engine contract.
function engineSettings(overrides: Partial<EngineSettings> = {}): EngineSettings {
  return {
    vaultSelected: true,
    scanTimes: ["2026-09-14T06:00:00-07:00", "2026-09-14T12:00:00-07:00", "2026-09-14T21:00:00-07:00"],
    safety: {
      mode: "send-and-schedule",
      externalWrites: true,
      label: "Send & schedule · nothing leaves without your confirmation",
    },
    capability: {
      canSend: true,
      canSchedule: true,
      canReschedule: true,
      canDraft: true,
      canReadBody: true,
      canSummarize: true,
    },
    assist: {
      enabled: true,
      provider: "Claude (your subscription)",
      contentLeavesMachine: true,
      label: "Drafting on · Claude (your subscription) · the message you draft against leaves this Mac",
    },
    source: { kind: "connected", live: true, label: "Your account" },
    ...overrides,
  };
}

function data(overrides: Partial<SettingsData> = {}): SettingsData {
  return {
    settings: engineSettings(),
    calendars: [
      { id: "c1", title: "School", role: "planning" },
      { id: "c2", title: "Career", role: "planning" },
      { id: "c3", title: "Holidays in Canada", role: "excluded" },
    ],
    health: { ok: true, mode: "send-and-schedule" },
    ...overrides,
  };
}

async function render(load?: () => Promise<SettingsData>) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(createElement(Settings, load ? { load } : {}));
  });
  return host;
}

function section(id: string): HTMLElement {
  const el = host!.querySelector<HTMLElement>(`#settings-${id}`);
  if (!el) throw new Error(`no section ${id}`);
  return el;
}

describe("Settings", () => {
  it("renders every section from engine data", async () => {
    const el = await render(async () => data());

    expect(el.querySelector("h1")?.textContent).toBe("How Daily Planner is set up");

    const account = section("account");
    expect(account.textContent).toContain("Connected");
    expect(account.textContent).toContain("Read + write");
    expect(account.textContent).toContain("Send & schedule · nothing leaves without your confirmation");
    expect(account.textContent).toContain("Daily Planner › Settings…");

    const calendars = section("calendars");
    expect(calendars.textContent).toContain("2 planning · 1 excluded");
    expect(calendars.textContent).toContain("Holidays in Canada");
    expect(calendars.textContent).toContain("Excluded");

    const drafting = section("drafting");
    expect(drafting.textContent).toContain("Claude (your subscription)");
    expect(drafting.textContent).toContain("What leaves this Mac");
    expect(drafting.textContent).toContain("To Claude (your subscription)");

    const ranking = section("ranking");
    const topics = [...ranking.querySelectorAll("ol li")].map((li) => li.textContent);
    expect(topics.map((t) => t?.replace(/^\d/, ""))).toEqual([
      expect.stringContaining("School"),
      expect.stringContaining("Recruiting"),
      expect.stringContaining("Finance"),
      expect.stringContaining("Personal"),
      expect.stringContaining("Other"),
    ]);
    expect(ranking.textContent).toContain("Security warning");
    expect(ranking.textContent).toContain("Not editable yet");

    const scans = section("scans");
    expect(scans.textContent).toContain("6:00");
    expect(scans.textContent).toContain("21:00");
    expect(scans.textContent).toContain("Allowed");

    expect(section("shortcuts").querySelectorAll("kbd").length).toBeGreaterThan(4);
    expect(section("about").textContent).toContain("Running");

    // No sample banner on a live account.
    expect(el.textContent).not.toContain("Sample data");
  });

  it("says read-only, and that nothing goes to Google, on a read-only grant", async () => {
    const el = await render(async () =>
      data({
        settings: engineSettings({
          safety: { mode: "read-only", externalWrites: false, label: "Read-only · no external writes" },
          capability: {
            canSend: false,
            canSchedule: false,
            canReschedule: false,
            canDraft: false,
            canReadBody: true,
            canSummarize: false,
          },
          assist: { enabled: false, provider: "", contentLeavesMachine: false, label: "" },
        }),
      }),
    );
    expect(section("account").textContent).toContain("Read only");
    expect(section("account").textContent).not.toContain("Read + write");
    const drafting = section("drafting");
    expect(drafting.textContent).toContain("Off");
    expect(drafting.textContent).toContain("Nothing. This connection can read, not write.");
    expect(drafting.textContent).toContain("Nothing — there is no assistant.");
    expect(el).toBeTruthy();
  });

  it("flags sample data instead of describing it as the account", async () => {
    const el = await render(async () =>
      data({
        settings: engineSettings({ source: { kind: "sample", live: false, label: "Sample data · not your account" } }),
      }),
    );
    expect(el.textContent).toContain("Sample data · not your account");
    expect(section("account").textContent).toContain("Not connected");
  });

  it("keeps the page when only the calendar list fails", async () => {
    await render(async () => data({ calendars: null, health: null }));
    expect(section("calendars").textContent).toContain("Couldn't read the calendar list");
    expect(section("about").textContent).toContain("Didn't answer a health check");
    expect(section("account").textContent).toContain("Read + write");
  });

  it("shows an error state with a retry when settings can't be read", async () => {
    let calls = 0;
    const el = await render(async () => {
      calls += 1;
      throw new ApiError("server_error", "The engine reported an error.");
    });
    expect(el.textContent).toContain("Couldn't read settings");
    const retry = [...el.querySelectorAll("button")].find((b) => b.textContent === "Try again");
    expect(retry).toBeTruthy();
    await act(async () => retry!.click());
    expect(calls).toBe(2);
  });

  it("shows the not-connected state without a token", async () => {
    vi.stubGlobal("fetch", vi.fn());
    const el = await render();
    expect(el.textContent).toContain("Not connected to the engine");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("only ever GETs read routes — no write call leaves this surface", async () => {
    window.__DP_TOKEN__ = "test-token";
    const routes: Record<string, unknown> = {
      "/api/settings": engineSettings(),
      "/api/calendars": { calendars: data().calendars },
      "/api/health": data().health,
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
      const path = String(input);
      return new Response(JSON.stringify(routes[path] ?? {}), {
        status: routes[path] ? 200 : 404,
        headers: { "Content-Type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const el = await render();
    expect(el.textContent).toContain("How Daily Planner is set up");

    // Click everything clickable. Nothing on this page may turn into a request.
    await act(async () => {
      el.querySelectorAll<HTMLElement>("button, a").forEach((b) => b.click());
    });

    const calls = fetchMock.mock.calls.map(([input, init]) => ({
      path: String(input),
      method: ((init as RequestInit | undefined)?.method ?? "GET").toUpperCase(),
    }));
    expect(calls.length).toBe(3);
    expect(calls.every((c) => c.method === "GET")).toBe(true);
    expect(calls.map((c) => c.path).sort()).toEqual(["/api/calendars", "/api/health", "/api/settings"]);
  });
});
