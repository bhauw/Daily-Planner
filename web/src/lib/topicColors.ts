/*
 * The palette a user-defined topic draws from.
 *
 * Categories are a closed set with fixed meanings — school is blue, finance is lavender, and a
 * workspace may not invent a sixth. Topics are the opposite: the user makes them, names them,
 * and will make more than anyone planned for. So they need their own palette, chosen on rules
 * rather than taste:
 *
 *   1. Legible. A topic colour is rendered as the tag's ink at 10px, so every entry clears
 *      4.5:1 as text on all three surfaces the app paints.
 *   2. Distinguishable. Every pair is at least dE76 24 apart, because a palette that passes
 *      contrast can still hand back an amber and an orange that nobody can tell apart in a
 *      list — which is the whole job of a topic colour.
 *
 * Both are recomputed from the real token values in topicColors.test.ts rather than asserted
 * as prose, so changing a hex re-measures instead of going stale.
 *
 * Assignment is deterministic, not random: a topic keeps its colour across restarts, across
 * machines and across a re-proposal, because a colour that moves is worse than no colour. The
 * user can always override it — `assignColor` only answers "what should this one be by
 * default", and a stored choice wins.
 */

/** The palette's names. The token is `--topic-<name>`. */
export const TOPIC_COLORS = [
  "blue",
  "sky",
  "teal",
  "green",
  "lime",
  "yellow",
  "orange",
  "red",
  "pink",
  "magenta",
  "violet",
  "slate",
] as const;

export type TopicColor = (typeof TOPIC_COLORS)[number];

/** What a colour is called in the picker. Title case of the token name. */
export function topicColorLabel(color: TopicColor): string {
  return color[0].toUpperCase() + color.slice(1);
}

/** The CSS variable reference to paint with. Never a raw hex in a component. */
export function topicColorVar(color: TopicColor): string {
  return `var(--topic-${color})`;
}

export function isTopicColor(value: string): value is TopicColor {
  return (TOPIC_COLORS as readonly string[]).includes(value);
}

/**
 * A stable hash of a topic's identity. Small, fast, and — the only property that matters —
 * the same answer every time for the same string.
 *
 * FNV-1a, with `>>> 0` after the multiply so it stays an unsigned 32-bit value. Without that,
 * JavaScript's bitwise operators would drift into negatives and the modulo below could return
 * a negative index.
 */
function hash(text: string): number {
  let value = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 0x01000193) >>> 0;
  }
  return value >>> 0;
}

/**
 * The colour a topic gets when nobody has chosen one.
 *
 * `taken` is the colours already in use. The palette is walked from the hashed starting point
 * so the first free colour wins, which keeps a small set of topics fully distinct instead of
 * letting a hash collision hand two topics the same colour while nine go unused. Once every
 * colour is spoken for it wraps and repeats, which is honest — twelve topics is a lot, and
 * repeating beats inventing an unreadable thirteenth.
 */
export function assignColor(topicId: string, taken: Iterable<TopicColor> = []): TopicColor {
  const used = new Set(taken);
  const start = hash(topicId) % TOPIC_COLORS.length;
  for (let step = 0; step < TOPIC_COLORS.length; step++) {
    const candidate = TOPIC_COLORS[(start + step) % TOPIC_COLORS.length];
    if (!used.has(candidate)) return candidate;
  }
  return TOPIC_COLORS[start];
}

/**
 * Colours for a whole list of topics at once, in order.
 *
 * Order matters and is the caller's: the topics are ranked, so the highest-priority topic
 * picks first and keeps its colour when a lower one is added, renamed or deleted.
 */
export function assignColors(topicIds: readonly string[]): Map<string, TopicColor> {
  const out = new Map<string, TopicColor>();
  const used = new Set<TopicColor>();
  for (const id of topicIds) {
    const color = assignColor(id, used);
    used.add(color);
    out.set(id, color);
  }
  return out;
}
