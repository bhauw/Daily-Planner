/*
 * Mount smoke test.
 *
 * The production WKWebView has `isInspectable = false`, so a runtime error at module init or
 * first render shows up as a completely blank window with NO console, NO log line and nothing in
 * the accessibility tree. That is indistinguishable from "the engine is down" from the outside,
 * and it is exactly how a blank build shipped. This renders the real shell in jsdom so the same
 * failure surfaces as a test error with a stack.
 */

// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";

// React 18.3 wants this set before act() is used outside a test renderer.
(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";

describe("the shell mounts", () => {
  it("renders without throwing, even with no engine behind it", async () => {
    // No token and no server: the shell must still mount and show its disconnected state.
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("no engine")));

    const { App } = await import("./app");
    const host = document.createElement("div");
    document.body.appendChild(host);

    await act(async () => {
      createRoot(host).render(createElement(App));
    });

    expect(host.textContent).toBeTruthy();
  });
});
