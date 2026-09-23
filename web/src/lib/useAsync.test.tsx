/*
 * A write used to reload the shell by flipping it back to "loading", which unmounted the whole
 * surface: open rows collapsed, scroll reset and focus fell to <body> after every send. A reload
 * with data already on screen now refreshes behind it.
 */

// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { ApiError } from "../api/client";
import { useAsync, type AsyncState } from "./useAsync";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function harness(loader: () => Promise<number>) {
  const seen: AsyncState<number>[] = [];
  function Probe() {
    seen.push(useAsync(loader));
    return null;
  }
  const host = document.createElement("div");
  const root = createRoot(host);
  await act(async () => root.render(createElement(Probe)));
  return { latest: () => seen[seen.length - 1], seen, unmount: () => act(() => root.unmount()) };
}

describe("useAsync", () => {
  it("refreshes in the background without returning to loading once it has data", async () => {
    let next = deferred<number>();
    const h = await harness(() => next.promise);
    await act(async () => next.resolve(1));
    expect(h.latest().status).toBe("ready");

    next = deferred<number>();
    const from = h.seen.length;
    await act(async () => h.latest().reload());
    // In flight: still the old data, still ready — nothing for the surface to unmount over.
    expect(h.latest().status).toBe("ready");
    expect(h.latest().data).toBe(1);
    expect(h.latest().refreshing).toBe(true);

    await act(async () => next.resolve(2));
    expect(h.latest().data).toBe(2);
    expect(h.latest().refreshing).toBe(false);
    expect(h.seen.slice(from).every((s) => s.status === "ready")).toBe(true);
    h.unmount();
  });

  it("keeps what is on screen when a background refresh fails", async () => {
    let next = deferred<number>();
    const h = await harness(() => next.promise);
    await act(async () => next.resolve(1));

    next = deferred<number>();
    await act(async () => h.latest().reload());
    await act(async () => next.reject(new ApiError("not_connected", "gone")));

    expect(h.latest().status).toBe("ready");
    expect(h.latest().data).toBe(1);
    expect(h.latest().error?.code).toBe("not_connected");
    h.unmount();
  });

  it("still shows loading on the first load", async () => {
    const next = deferred<number>();
    const h = await harness(() => next.promise);
    expect(h.latest().status).toBe("loading");
    await act(async () => next.resolve(1));
    h.unmount();
  });
});
