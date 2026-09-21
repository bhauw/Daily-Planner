/*
 * PressureBar — the workload meter under the Today dayline.
 *
 * Form (per dataviz): this is a single-value magnitude meter, not a chart. The
 * encoding that carries meaning is the FILL LENGTH; colour is a single amber hue
 * stepped light->dark (a valid sequential scale). We deliberately do NOT use the
 * mockup's career-yellow -> warn-orange gradient: that mixes two reserved
 * category colours and reads as two encodings. The level word ("Calm/Moderate/
 * High") is carried in TEXT and in aria-valuetext, so the state is never
 * conveyed by colour alone. Label text wears --text-2, never the fill colour.
 */

import "./pressure-bar.css";

export type PressureLevel = "calm" | "moderate" | "high";

interface PressureBarProps {
  /** 0..1 fraction of the planning window that is committed. */
  value: number;
  /** short state phrase, e.g. "High · 2 back-to-back". */
  detail: string;
}

export function levelFor(value: number): PressureLevel {
  if (value >= 0.66) return "high";
  if (value >= 0.33) return "moderate";
  return "calm";
}

const LEVEL_WORD: Record<PressureLevel, string> = {
  calm: "Calm",
  moderate: "Moderate",
  high: "High",
};

export function PressureBar({ value, detail }: PressureBarProps) {
  const clamped = Math.max(0, Math.min(1, value));
  const level = levelFor(clamped);
  const pct = Math.round(clamped * 100);
  const word = LEVEL_WORD[level];

  return (
    <div className="pressure">
      <span className="pressure__label">Workload</span>
      <span
        className="pressure__track"
        role="meter"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={pct}
        aria-valuetext={`${word}, ${pct} percent of the day committed`}
        aria-label="Workload pressure"
      >
        <span className={`pressure__fill pressure__fill--${level}`} style={{ width: `${pct}%` }} />
      </span>
      <span className="num pressure__detail">{detail}</span>
    </div>
  );
}
