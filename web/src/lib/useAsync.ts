/*
 * useAsync — run a one-shot async loader on mount and expose {status, data,
 * error}. Deliberately does NOT retry on its own: when the engine is absent the
 * client throws ApiError("not_connected") and we surface a clear disconnected
 * state instead of looping. A manual reload() is provided for an explicit retry.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api/client";

export type AsyncStatus = "loading" | "ready" | "disconnected" | "error";

export interface AsyncState<T> {
  status: AsyncStatus;
  data: T | null;
  error: ApiError | null;
  reload: () => void;
}

export function useAsync<T>(loader: () => Promise<T>): AsyncState<T> {
  const [status, setStatus] = useState<AsyncStatus>("loading");
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;

  const run = useCallback(() => {
    let cancelled = false;
    setStatus("loading");
    loaderRef
      .current()
      .then((result) => {
        if (cancelled) return;
        setData(result);
        setError(null);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        const apiErr =
          err instanceof ApiError ? err : new ApiError("bad_response", "Unexpected error.");
        setError(apiErr);
        setStatus(apiErr.code === "not_connected" ? "disconnected" : "error");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => run(), [run]);

  return { status, data, error, reload: run };
}
