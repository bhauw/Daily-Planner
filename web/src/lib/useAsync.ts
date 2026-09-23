/*
 * useAsync — run a one-shot async loader on mount and expose {status, data,
 * error}. Deliberately does NOT retry on its own: when the engine is absent the
 * client throws ApiError("not_connected") and we surface a clear disconnected
 * state instead of looping. A manual reload() is provided for an explicit retry.
 *
 * reload() with data already on screen is a BACKGROUND refresh: status stays "ready" and the old
 * data stays until the new arrives. It used to flip back to "loading", and the shell swaps the
 * whole surface for a spinner on "loading" — so every send unmounted the day under the user:
 * open rows collapsed, scroll reset, and focus fell to <body>. A refresh that fails keeps what
 * is on screen too, with the error reported beside it; blanking a day that was fine a second
 * ago over a failed re-read is worse than showing it slightly stale.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";

export type AsyncStatus = "loading" | "ready" | "disconnected" | "error";

export interface AsyncState<T> {
  status: AsyncStatus;
  data: T | null;
  error: ApiError | null;
  /** True while a background refresh is in flight over data already shown. */
  refreshing: boolean;
  reload: () => void;
}

export function useAsync<T>(loader: () => Promise<T>): AsyncState<T> {
  const [status, setStatus] = useState<AsyncStatus>("loading");
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  // Read inside `run` without making it depend on `data`, so reload keeps a stable identity.
  const hasData = useRef(false);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;

  const run = useCallback(() => {
    let cancelled = false;
    const background = hasData.current;
    if (background) setRefreshing(true);
    else setStatus("loading");
    loaderRef
      .current()
      .then((result) => {
        if (cancelled) return;
        hasData.current = true;
        setData(result);
        setError(null);
        setStatus("ready");
        setRefreshing(false);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        const apiErr =
          err instanceof ApiError ? err : new ApiError("bad_response", "Unexpected error.");
        setError(apiErr);
        setRefreshing(false);
        if (!background) setStatus(apiErr.code === "not_connected" ? "disconnected" : "error");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => run(), [run]);

  return { status, data, error, refreshing, reload: run };
}
