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

/** Mix `a` over `b` at share `p` (0-1), per channel in sRGB — what color-mix(in srgb) does. */
function mix(a: string, b: string, p: number): string {
  const rgb = (h: string) => {
    const n = Number.parseInt(h.replace("#", ""), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  };
  const [x, y] = [rgb(a), rgb(b)];
  return `#${x.map((v, i) => Math.round(v * p + y[i] * (1 - p)).toString(16).padStart(2, "0")).join("")}`;
}

describe("interaction and chrome tokens", () => {
  it("small text stays legible on the hover and pressed steps", () => {
    for (const depth of ["--surface-hover", "--surface-pressed", "--chrome"]) {
      for (const ink of ["--text", "--text-2", "--accent-text"]) {
        const ratio = contrast(token(ink), token(depth));
        expect({ pair: `${ink} on ${depth}`, pass: ratio >= 4.5 }).toEqual({
          pair: `${ink} on ${depth}`,
          pass: true,
        });
      }
    }
  });

  it("the hover step is a visible step up from --bg", () => {
    // The old hover (--surface on --bg) was 1.10:1 and read as nothing happening.
    expect(contrast(token("--surface-hover"), token("--bg"))).toBeGreaterThan(1.15);
    expect(contrast(token("--surface-pressed"), token("--bg"))).toBeGreaterThan(
      contrast(token("--surface-hover"), token("--bg")),
    );
  });

  it("pressed primary is visibly darker than hover, and still clears 4.5:1", () => {
    const hover = contrast(token("--accent-fill-ink"), token("--accent-fill-hover"));
    const active = contrast(token("--accent-fill-ink"), token("--accent-fill-active"));
    expect(active - hover).toBeGreaterThan(1);
    expect(active).toBeGreaterThanOrEqual(4.5);
  });

  it("disabled controls still clear 4.5:1 although WCAG exempts them", () => {
    expect(contrast(token("--disabled-ink"), token("--disabled-bg"))).toBeGreaterThanOrEqual(4.5);
  });

  it("the safety rail's amber marks and ink clear their thresholds on --chrome", () => {
    expect(contrast(token("--warn"), token("--chrome"))).toBeGreaterThanOrEqual(4.5);
    expect(contrast(token("--text"), token("--chrome"))).toBeGreaterThanOrEqual(4.5);
  });
});

describe("category tag on its tint", () => {
  const tint = Number.parseFloat(token("--tag-tint")) / 100;
  // Every ink category.ts can hand a .tag.
  const INKS = [
    "--cat-school-ink",
    "--cat-deadline",
    "--cat-finance",
    "--cat-extracurricular",
    "--cat-career",
    "--cat-personal-ink",
    "--cat-neutral-ink",
  ];
  const SURFACES = [...DEPTHS, "--surface-hover"];

  it("reads the tint from tokens.css", () => {
    expect(tint).toBeGreaterThan(0);
    expect(tint).toBeLessThanOrEqual(0.1);
  });

  it("every category ink clears 4.5:1 on its own tint over every surface", () => {
    for (const ink of INKS) {
      for (const depth of SURFACES) {
        const fg = token(ink);
        const ratio = contrast(fg, mix(fg, token(depth), tint));
        expect({ pair: `${ink} tag on ${depth}`, pass: ratio >= 4.5 }).toEqual({
          pair: `${ink} tag on ${depth}`,
          pass: true,
        });
      }
    }
  });

  it(".tag paints that tint, in sans, without an outline", () => {
    const badge = readFileSync(join(SRC, "components/badge.css"), "utf8");
    const tag = badge.slice(badge.indexOf(".tag {"), badge.indexOf("}", badge.indexOf(".tag {")));
    expect(tag).toMatch(/color-mix\(in srgb, currentColor var\(--tag-tint\), transparent\)/);
    expect(tag).toMatch(/font-family:\s*var\(--font-sans\)/);
    expect(tag).not.toMatch(/border:/);
  });
});

describe("a done task is dimmed by colour, not opacity", () => {
  // An audit found `.task--done { opacity: 0.6; }` multiplying every descendant's alpha,
  // including the category tag and the due-date/"Done" label, dragging both below 4.5:1
  // (measured: .task--done .tag 2.81:1, .task--done .task__due 2.69:1). Done rows are dimmed
  // through explicit tokens instead — the card recedes onto --surface (tasks.css) and the tag's
  // ink is muted to --text-2 (TaskCard.tsx) — so nothing here depends on a scaled-down alpha.
  const tasks = readFileSync(join(SRC, "workspaces/tasks/tasks.css"), "utf8");
  const doneBlock = tasks.slice(tasks.indexOf(".task--done {"), tasks.indexOf("}", tasks.indexOf(".task--done {")));

  it("never dims the row with opacity", () => {
    expect(doneBlock).not.toMatch(/opacity/);
  });

  it("the done tag's muted ink clears 4.5:1 on its own tint, on --surface (the done card's background)", () => {
    const tint = Number.parseFloat(token("--tag-tint")) / 100;
    const ink = token("--text-2");
    const ratio = contrast(ink, mix(ink, token("--surface"), tint));
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  it("the due-date/\"Done\" label clears 4.5:1 on --surface, the done card's background", () => {
    expect(contrast(token("--text-2"), token("--surface"))).toBeGreaterThanOrEqual(4.5);
  });
});

describe("default-variant button borders clear 3:1 non-text contrast", () => {
  // axe's non-text pass flagged .btn--default ("Reply", "Find in Gmail", "Copy address")
  // repeatedly around fillRatio/bRatio ~1.1-1.2 against the surrounding page (need 3:1) — the
  // base .btn border (--border, 1.34:1 on --surface by its own token comment) was too close in
  // luminance to read as a boundary at all (WCAG 1.4.11 Non-text Contrast — audit finding #10/#11).
  const SURROUNDING = ["--bg", "--chrome", "--surface", "--surface-2", "--surface-hover", "--surface-pressed"];

  it("--btn-border clears 3:1 against every background a default button sits on", () => {
    for (const bg of SURROUNDING) {
      const ratio = contrast(token("--btn-border"), token(bg));
      expect({ pair: `--btn-border on ${bg}`, pass: ratio >= 3 }).toEqual({
        pair: `--btn-border on ${bg}`,
        pass: true,
      });
    }
  });

  it(".btn--default actually paints its border in --btn-border, not the low-contrast --border", () => {
    const button = readFileSync(join(SRC, "components/button.css"), "utf8");
    const rule = button.slice(button.indexOf(".btn--default"));
    const block = rule.slice(0, rule.indexOf("}"));
    expect(block).toMatch(/border-color:\s*var\(--btn-border\)/);
  });
});

describe("stylesheets honour the token rules", () => {
  it("never fills a primary button with --accent", () => {
    const button = readFileSync(join(SRC, "components/button.css"), "utf8");
    const primary = button.slice(button.indexOf(".btn--primary"));
    expect(primary).not.toMatch(/background:\s*var\(--accent\)/);
    expect(primary).toMatch(/background:\s*var\(--accent-fill\)/);
  });

  it("never writes a raw hex background in the shell layout", () => {
    const shell = readFileSync(join(SRC, "shell/three-column.css"), "utf8");
    expect(shell).not.toMatch(/background:\s*#/);
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
