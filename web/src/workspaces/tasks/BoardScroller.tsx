/*
 * BoardScroller — the horizontally scrolling row of list columns, with a visible cue at each
 * edge that has more columns past it.
 *
 * The board already scrolled sideways, but nothing said so: macOS hides overlay scrollbars until
 * you scroll, so at 1440 the fourth column was simply cut in half behind the focus pane and read
 * as a broken layout. Each clipped edge now gets a fade and a chevron that pages one column
 * along. The chevrons are a pointer convenience only — the region itself is focusable and scrolls
 * with the arrow keys — so they stay out of the tab order and the accessibility tree.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { ChevronIcon } from "./icons";

interface Edges {
  start: boolean;
  end: boolean;
}

/** Which edges have content past them. A pixel of slack absorbs sub-pixel scroll positions. */
export function overflowEdges(el: Pick<HTMLElement, "scrollLeft" | "scrollWidth" | "clientWidth">): Edges {
  return {
    start: el.scrollLeft > 1,
    end: el.scrollLeft + el.clientWidth < el.scrollWidth - 1,
  };
}

export function BoardScroller({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState<Edges>({ start: false, end: false });

  const measure = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    const next = overflowEdges(el);
    setEdges((prev) => (prev.start === next.start && prev.end === next.end ? prev : next));
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    measure();
    el.addEventListener("scroll", measure, { passive: true });
    window.addEventListener("resize", measure);
    // jsdom has no ResizeObserver; the window listener still covers the real app.
    const ro = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure);
    ro?.observe(el);
    if (el.firstElementChild) ro?.observe(el.firstElementChild);
    return () => {
      el.removeEventListener("scroll", measure);
      window.removeEventListener("resize", measure);
      ro?.disconnect();
    };
  }, [measure]);

  function page(dir: 1 | -1) {
    const el = ref.current;
    if (!el) return;
    const column = el.querySelector<HTMLElement>(".tasklist");
    const step = column ? column.offsetWidth + 8 : el.clientWidth * 0.8;
    const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    el.scrollBy({ left: dir * step, behavior: reduce ? "auto" : "smooth" });
  }

  return (
    <div className="tasks__board">
      <div ref={ref} className="tasks__lists" role="region" aria-label="Task lists" tabIndex={0}>
        {children}
      </div>
      {edges.start && (
        <div className="tasks__edge tasks__edge--start" aria-hidden="true">
          <button type="button" className="tasks__edge-btn" tabIndex={-1} title="Earlier lists" onClick={() => page(-1)}>
            <ChevronIcon dir="left" />
          </button>
        </div>
      )}
      {edges.end && (
        <div className="tasks__edge tasks__edge--end" aria-hidden="true">
          <button type="button" className="tasks__edge-btn" tabIndex={-1} title="More lists" onClick={() => page(1)}>
            <ChevronIcon dir="right" />
          </button>
        </div>
      )}
    </div>
  );
}
