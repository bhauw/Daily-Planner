/*
 * Column packing for the week/day grids: lay overlapping events side by side
 * instead of stacking them into illegibility. Events that overlap in time form a
 * cluster; within a cluster each event takes the first free column, and every
 * member is widened to 1/cols of the day column.
 */

import type { PlannerEvent } from "../contract";
import { eventInterval } from "./scheduling";

export const WINDOW_START = 7 * 60; // 07:00 — shows the day plus the 6–8 PM fallback band
export const WINDOW_END = 21 * 60; // 21:00
export const HOUR_PX = 48;
export const PX_PER_MIN = HOUR_PX / 60;

export interface Positioned {
  event: PlannerEvent;
  start: number;
  end: number;
  col: number;
  cols: number;
}

interface Item {
  event: PlannerEvent;
  start: number;
  end: number;
}

export function layoutColumns(events: PlannerEvent[]): Positioned[] {
  const items: Item[] = [];
  for (const e of events) {
    const iv = eventInterval(e);
    if (!iv) continue;
    items.push({ event: e, start: iv.start, end: Math.max(iv.end, iv.start + 20) });
  }
  items.sort((a, b) => a.start - b.start || a.end - b.end);

  const result: Positioned[] = [];
  let cluster: Item[] = [];
  let clusterEnd = -Infinity;

  const flush = () => {
    if (cluster.length === 0) return;
    const colEnds: number[] = [];
    const assign: number[] = [];
    for (const it of cluster) {
      let placed = -1;
      for (let c = 0; c < colEnds.length; c++) {
        if (colEnds[c] <= it.start) {
          placed = c;
          break;
        }
      }
      if (placed === -1) {
        placed = colEnds.length;
        colEnds.push(it.end);
      } else {
        colEnds[placed] = it.end;
      }
      assign.push(placed);
    }
    const cols = colEnds.length;
    cluster.forEach((it, i) =>
      result.push({ event: it.event, start: it.start, end: it.end, col: assign[i], cols }),
    );
    cluster = [];
  };

  for (const it of items) {
    if (cluster.length === 0) {
      clusterEnd = it.end;
      cluster.push(it);
      continue;
    }
    if (it.start >= clusterEnd) {
      flush();
      clusterEnd = it.end;
      cluster.push(it);
    } else {
      cluster.push(it);
      clusterEnd = Math.max(clusterEnd, it.end);
    }
  }
  flush();
  return result;
}

/** Pixel geometry for a block within the WINDOW_START..WINDOW_END band. */
export function blockGeometry(pos: Positioned): { top: number; height: number; leftPct: number; widthPct: number } {
  const top = (pos.start - WINDOW_START) * PX_PER_MIN;
  const height = Math.max(20, (pos.end - pos.start) * PX_PER_MIN);
  const widthPct = 100 / pos.cols;
  const leftPct = pos.col * widthPct;
  return { top, height, leftPct, widthPct };
}
