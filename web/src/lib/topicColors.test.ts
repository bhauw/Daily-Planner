/*
 * The two properties a topic palette has to have, recomputed from the real tokens.
 *
 * Asserted rather than described, and measured from tokens.css rather than from a copy, so
 * editing a hex re-measures instead of quietly going stale. This is the same approach
 * contrast.test.ts takes for the semantic tokens, applied to the palette the user picks from.
 *
 * Contrast alone is not enough and that is the interesting half: a palette can pass every
 * legibility check and still contain an amber and an orange that nobody can tell apart in a
 * list, which defeats the entire point of colouring a topic. So separation is a test too.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  TOPIC_COLORS,
  assignColor,
  assignColors,
  isTopicColor,
  topicColorLabel,
  topicColorVar,
  type TopicColor,
} from "./topicColors";

const TOKENS = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../tokens.css"), "utf8");

/** The surfaces the app actually paints. --surface-2 is the lightest and so the worst case. */
const SURFACES = { "--bg": "#1e1e1e", "--surface": "#252525", "--surface-2": "#2c2c2c" };

function token(name: string): string {
  const match = TOKENS.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`));
  if (!match) throw new Error(`no literal value for ${name}`);
  return match[1].toLowerCase();
}

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as [number, number, number];
}

function luminance(hex: string): number {
  const channel = (c: number) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  const [r, g, b] = rgb(hex).map(channel);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** CIE L*a*b*, for a perceptual distance rather than an RGB one. */
function lab(hex: string): [number, number, number] {
  const channel = (c: number) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  const [r, g, b] = rgb(hex).map(channel);
  const x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

function deltaE(a: string, b: string): number {
  const [la, aa, ba] = lab(a);
  const [lb, ab, bb] = lab(b);
  return Math.hypot(la - lb, aa - ab, ba - bb);
}

const HEXES = new Map<TopicColor, string>(TOPIC_COLORS.map((c) => [c, token(`--topic-${c}`)]));

describe("every topic colour is legible as tag ink", () => {
  it.each(TOPIC_COLORS)("%s clears 4.5:1 on every surface the app paints", (color) => {
    const hex = HEXES.get(color)!;
    for (const [name, surface] of Object.entries(SURFACES)) {
      const ratio = contrast(hex, surface);
      expect(ratio, `${color} (${hex}) on ${name}`).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("holds on --surface-2, which is the lightest and therefore the real test", () => {
    const worst = Math.min(...TOPIC_COLORS.map((c) => contrast(HEXES.get(c)!, SURFACES["--surface-2"])));
    expect(worst).toBeGreaterThanOrEqual(4.5);
  });
});

describe("every topic colour is tellable from every other", () => {
  it("keeps all 66 pairs at least dE 20 apart", () => {
    const tooClose: string[] = [];
    for (let i = 0; i < TOPIC_COLORS.length; i++) {
      for (let j = i + 1; j < TOPIC_COLORS.length; j++) {
        const [a, b] = [TOPIC_COLORS[i], TOPIC_COLORS[j]];
        const distance = deltaE(HEXES.get(a)!, HEXES.get(b)!);
        if (distance < 20) tooClose.push(`${a}/${b} (dE ${distance.toFixed(1)})`);
      }
    }
    expect(tooClose).toEqual([]);
  });

  it("has no duplicate hexes hiding behind distinct names", () => {
    expect(new Set(HEXES.values()).size).toBe(TOPIC_COLORS.length);
  });
});

describe("the two failing category inks were actually fixed", () => {
  // Both shipped under the floor as 10px tag text. Pinned so the fix cannot be reverted by
  // someone tidying the token list.
  it("--cat-school-ink is legible where --cat-school was not", () => {
    expect(contrast("#0a84ff", SURFACES["--surface-2"])).toBeLessThan(4.5); // the old value
    expect(contrast(token("--topic-blue"), SURFACES["--surface-2"])).toBeGreaterThanOrEqual(4.5);
  });

  it("--cat-personal-ink is legible where --cat-personal was not", () => {
    expect(contrast("#ff00ff", SURFACES["--surface-2"])).toBeLessThan(4.5); // the old value
    expect(contrast(token("--topic-magenta"), SURFACES["--surface-2"])).toBeGreaterThanOrEqual(4.5);
  });
});

describe("a topic keeps its colour", () => {
  it("gives the same answer every time for the same topic", () => {
    expect(assignColor("recruiting")).toBe(assignColor("recruiting"));
  });

  it("does not depend on what else exists, when nothing is taken", () => {
    expect(assignColor("bus-251", [])).toBe(assignColor("bus-251"));
  });

  it("never hands out a colour already in use while one is free", () => {
    const taken = TOPIC_COLORS.slice(0, TOPIC_COLORS.length - 1);
    expect(assignColor("anything", taken)).toBe(TOPIC_COLORS[TOPIC_COLORS.length - 1]);
  });

  it("repeats rather than inventing a thirteenth colour once all are taken", () => {
    const color = assignColor("overflow", TOPIC_COLORS);
    expect(isTopicColor(color)).toBe(true);
  });

  it("gives a distinct colour to every topic in a list of twelve", () => {
    const ids = Array.from({ length: 12 }, (_, i) => `topic-${i}`);
    const assigned = assignColors(ids);
    expect(new Set(assigned.values()).size).toBe(12);
  });

  it("keeps the higher-ranked topics' colours when a lower one is added", () => {
    const before = assignColors(["school", "recruiting", "finance"]);
    const after = assignColors(["school", "recruiting", "finance", "investing"]);
    for (const id of ["school", "recruiting", "finance"]) {
      expect(after.get(id), `${id} moved`).toBe(before.get(id));
    }
  });

  it("keeps the higher-ranked topics' colours when a lower one is deleted", () => {
    const before = assignColors(["school", "recruiting", "finance"]);
    const after = assignColors(["school", "recruiting"]);
    expect(after.get("school")).toBe(before.get("school"));
    expect(after.get("recruiting")).toBe(before.get("recruiting"));
  });
});

describe("presentation helpers", () => {
  it("names a colour for the picker", () => {
    expect(topicColorLabel("magenta")).toBe("Magenta");
  });

  it("paints through the token, never a raw hex", () => {
    expect(topicColorVar("teal")).toBe("var(--topic-teal)");
    for (const color of TOPIC_COLORS) expect(topicColorVar(color)).not.toContain("#");
  });

  it("rejects a colour name that is not in the palette", () => {
    expect(isTopicColor("chartreuse")).toBe(false);
    expect(isTopicColor("blue")).toBe(true);
  });
});
