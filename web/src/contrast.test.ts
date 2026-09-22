/*
 * Contrast guard.
 *
 * An audit found the accessibility rule that tokens.css writes for itself was not
 * being kept: --text-3 (3.29:1 on --bg, 2.75:1 on --surface-2) was carrying 10-11px
 * text in 20 declarations, and every filled primary button put white on --accent at
 * 3.65:1. These tests read the real stylesheets, so the rule is enforced rather than
 * merely documented.
 *
 * The ratios are computed from the token values themselves — change a token and the
 * test re-measures rather than going stale.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC = dirname(fileURLToPath(import.meta.url));

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return cssFiles(full);
    return name.endsWith(".css") ? [full] : [];
  });
}

const FILES = cssFiles(SRC).sort();
const TOKENS = readFileSync(join(SRC, "tokens.css"), "utf8");

/** Resolve a token to a #rrggbb literal, following one level of aliasing. */
function token(name: string): string {
  const seen = new Set<string>();
  let value = name;
  while (value.startsWith("--")) {
    if (seen.has(value)) throw new Error(`token cycle at ${value}`);
    seen.add(value);
    const m = TOKENS.match(new RegExp(`\\n\\s*${value}:\\s*([^;]+);`));
    if (!m) throw new Error(`token ${value} not declared in tokens.css`);
    const raw = m[1].trim();
    const alias = raw.match(/^var\((--[\w-]+)\)$/);
    value = alias ? alias[1] : raw;
  }
  return value;
}

const channel = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);

function luminance(hex: string): number {
  const n = Number.parseInt(hex.replace("#", ""), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => channel(v / 255));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/** The three depths the app paints text on. */
const DEPTHS = ["--bg", "--surface", "--surface-2"] as const;

/**
 * Rules that may keep --text-3. Each is decorative, a non-text mark, or a disabled
 * state — the three cases WCAG exempts. Adding a selector here is a deliberate act.
 */
const TEXT_3_EXEMPT = new Set([
  ".task__grip", // drag handle glyph
  ".task--done .task__title", // strikethrough rule on a completed task
  ".field__textarea:disabled", // :disabled is exempt from contrast
  ".compose__custominput:disabled", // likewise: greyed while a draft is being written
  ".focus__caret", // disclosure chevron
  ".drow__caret", // disclosure chevron
]);

describe("token contrast", () => {
  it("body ink clears 4.5:1 on every surface the app paints", () => {
    for (const ink of ["--text", "--text-2"]) {
      for (const depth of DEPTHS) {
        const ratio = contrast(token(ink), token(depth));
        // Name the pair in the message so a failure says which one dropped.
        expect({ pair: `${ink} on ${depth}`, pass: ratio >= 4.5 }).toEqual({
          pair: `${ink} on ${depth}`,
          pass: true,
        });
      }
    }
  });

  it("--text-3 still fails 4.5:1, which is why its use is restricted", () => {
    // If a future palette change lifts it, delete the restriction rather than
    // leaving a rule nobody needs.
    expect(contrast(token("--text-3"), token("--bg"))).toBeLessThan(4.5);
  });

  it("white on --accent-fill clears 4.5:1 in every button state", () => {
    for (const fill of ["--accent-fill", "--accent-fill-hover", "--accent-fill-active"]) {
      expect(contrast(token("--accent-fill-ink"), token(fill))).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("--accent-text clears 4.5:1 on every surface, and plain --accent does not", () => {
    for (const depth of DEPTHS) {
      expect(contrast(token("--accent-text"), token(depth))).toBeGreaterThanOrEqual(4.5);
    }
    expect(contrast(token("--accent"), token("--surface"))).toBeLessThan(4.5);
  });
});

describe("stylesheets honour the token rules", () => {
  it("never fills a primary button with --accent", () => {
    const button = readFileSync(join(SRC, "components/button.css"), "utf8");
    const primary = button.slice(button.indexOf(".btn--primary"));
    expect(primary).not.toMatch(/background:\s*var\(--accent\)/);
    expect(primary).toMatch(/background:\s*var\(--accent-fill\)/);
  });

  it("uses --text-3 as a text colour only on exempt selectors", () => {
    const offenders: string[] = [];
    for (const file of FILES) {
      if (file.endsWith("tokens.css")) continue;
      const source = readFileSync(file, "utf8");
      for (const block of source.split("}")) {
        if (!/color:\s*var\(--text-3\)/.test(block)) continue;
        // text-decoration-color is a rule, not ink.
        if (!/(^|[\s;{])color:\s*var\(--text-3\)/.test(block)) continue;
        const selector = (block.split("{")[0] ?? "").trim().split("\n").pop()?.trim() ?? "";
        for (const one of selector.split(",").map((s) => s.trim())) {
          if (!TEXT_3_EXEMPT.has(one)) offenders.push(`${file.slice(SRC.length + 1)}: ${one}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
