/*
 * Settings — what the app is set up to do, read from the engine.
 *
 * READ-ONLY, and structurally so. Every setting that changes something (connecting Google,
 * assigning a calendar role, granting the vault folder) is written in-process by the native
 * window, straight to the Keychain and the encrypted store. None of it has an HTTP route, and
 * that is deliberate: a loopback page that could rewrite the account connection is a page that
 * a leaked token could rewrite it from. So this surface says what is true and where to change
 * it, and the only calls it can make are the three GETs in `loadSettings`.
 *
 * It used to be a placeholder pointing at the menu. The pointer is still here, per section,
 * but next to the thing it would change — "your connection is read-only; change it there" is
 * worth more than "settings are elsewhere".
 *
 * Tolerant like the shell: `/api/settings` is the surface, so failing it is the error state,
 * but calendars and health are extras and a failed read of either becomes a note in its own
 * section rather than a blank page.
 */

import { useRef, type MouseEvent, type ReactNode } from "react";
import {
  api,
  type Assist,
  type Capability,
  type CalendarSummary,
  type Health,
  type Settings as EngineSettings,
} from "../api/client";
import { ConnectionState, EmptyState } from "../components/Column";
import { formatTime } from "../lib/format";
import { topicColorVar, type TopicColor } from "../lib/topicColors";
import { useAsync } from "../lib/useAsync";
import { SCOPE_TITLE, SHORTCUTS, keyLabel } from "../shell/shortcuts";
import "./settings.css";

export interface SettingsData {
  settings: EngineSettings;
  /** Null when /api/calendars could not be read; the section says so. */
  calendars: CalendarSummary[] | null;
  /** Null when /api/health could not be read. */
  health: Health | null;
}

/** The surface's only I/O. GETs, all three; there is nothing here to write with. */
export async function loadSettings(): Promise<SettingsData> {
  const [settings, calendars, health] = await Promise.all([
    api.settings(),
    api.calendars().then((r) => r.calendars).catch(() => null),
    api.health().catch(() => null),
  ]);
  return { settings, calendars, health };
}

/*
 * The inbox order, as the engine ranks it today.
 *
 * Mirrors `TriageProfile.default` in TriageProfile.swift. There is no route that reports the
 * profile, and there is nothing yet that edits it — MailTriagePolicy ranks through `.default`
 * unconditionally — so the built-in profile IS the live one, and stating it is accurate rather
 * than a guess. The moment a stored profile exists this must be read from the engine instead;
 * a copy that can drift is only acceptable while there is nothing for it to drift from.
 */
const TRIAGE_TOPICS: { name: string; color: TopicColor; covers: string }[] = [
  { name: "School", color: "blue", covers: "Course, registrar and campus mail" },
  { name: "Recruiting", color: "violet", covers: "Career mail — recruiters, applications" },
  { name: "Finance", color: "teal", covers: "Banks, statements, bills" },
  { name: "Personal", color: "magenta", covers: "Clubs, friends, everything personal" },
  { name: "Other", color: "slate", covers: "Anything the categoriser can't place" },
];

const TRIAGE_OVERRIDES: { headline: string; examples: string }[] = [
  { headline: "Security warning", examples: "“new sign in”, “verify your identity”, “fraud alert”" },
  { headline: "Interview", examples: "“interview”, “phone screen”, “final round”" },
  { headline: "Payment or enrolment", examples: "“tuition”, “payment due”, “registration closes”" },
  { headline: "Has a deadline", examples: "“due today”, “action required”, “rsvp by”" },
];

/*
 * The shortcut list is the registry's (shell/shortcuts.ts) — the same one the "?" overlay
 * prints — so this page cannot advertise a key that does nothing. ⌘, is the native menu's,
 * not the web app's, so it stays in the menu-path hint below rather than in this list.
 */

/** Injected in tests; the app always shows the version the bundle was built as. */
const WEB_VERSION = typeof __APP_VERSION__ === "string" ? __APP_VERSION__ : "unknown";

interface SettingsProps {
  /** Injected in tests. Defaults to the engine. */
  load?: () => Promise<SettingsData>;
}

export function Settings({ load = loadSettings }: SettingsProps) {
  const { status, data, reload } = useAsync(load);
  const scrollRef = useRef<HTMLDivElement>(null);

  /*
   * The jump links scroll the section list and nothing else. A plain `#id` link (or
   * scrollIntoView) scrolls EVERY ancestor that can move, including the shell's
   * `overflow: hidden` surface — which slid the whole page up under the safety rail and left a
   * dead band at the bottom that no scrollbar could undo.
   */
  const jump = (event: MouseEvent<HTMLAnchorElement>, id: string) => {
    const scroller = scrollRef.current;
    const target = document.getElementById(id);
    if (!scroller || !target) return;
    event.preventDefault();
    scroller.scrollTo?.({ top: target.offsetTop - scroller.offsetTop - 16 });
  };

  if (status === "disconnected") return <ConnectionState onRetry={reload} />;
  if (status === "loading") {
    return (
      <div className="app__loading" role="status" aria-live="polite">
        Reading settings…
      </div>
    );
  }
  if (status === "error" || !data) {
    return (
      <EmptyState
        title="Couldn't read settings"
        detail="The engine didn't answer with its settings. Nothing was changed. Try again in a moment."
        action={
          <button type="button" className="btn btn--default btn--sm" onClick={reload}>
            Try again
          </button>
        }
      />
    );
  }

  const { settings, calendars, health } = data;

  return (
    <div className="settings">
      <header className="settings__head">
        <div className="colhead__eyebrow">Settings</div>
        <h1 className="settings__title">How Daily Planner is set up</h1>
        <p className="settings__summary">
          Read here, change in the app: open <MenuPath /> Account, calendar and vault changes are
          saved on this Mac, never through this window.
        </p>
        <nav className="settings__jump" aria-label="Settings sections">
          {SECTIONS.map((s) => (
            <a key={s.id} href={`#${s.id}`} className="settings__jumplink" onClick={(e) => jump(e, s.id)}>
              {s.label}
            </a>
          ))}
        </nav>
      </header>

      <div className="settings__scroll" ref={scrollRef}>
        {!settings.source.live && (
          <div className="settings__sample" role="status">
            <span className="settings__samplebadge">Sample data</span>
            <span>
              {settings.source.label}. What follows describes the sample engine, not a Google
              account — connect one in <MenuPath inline />
            </span>
          </div>
        )}

        <AccountSection settings={settings} />
        <CalendarsSection calendars={calendars} />
        <DraftingSection assist={settings.assist} capability={settings.capability} />
        <RankingSection />
        <ScansSection scanTimes={settings.scanTimes} vaultSelected={settings.vaultSelected} />
        <ShortcutsSection />
        <AboutSection health={health} />
      </div>
    </div>
  );
}

const SECTIONS = [
  { id: "settings-account", label: "Google" },
  { id: "settings-calendars", label: "Calendars" },
  { id: "settings-drafting", label: "Drafting" },
  { id: "settings-ranking", label: "Inbox ranking" },
  { id: "settings-scans", label: "Scans & vault" },
  { id: "settings-shortcuts", label: "Keyboard shortcuts" },
  { id: "settings-about", label: "About" },
] as const;

type SectionId = (typeof SECTIONS)[number]["id"];

// ---- Sections -----------------------------------------------------------------

function AccountSection({ settings }: { settings: EngineSettings }) {
  const { capability, safety, source } = settings;
  // Either flag is enough to call it a write grant: the rail keys off `externalWrites`, the
  // buttons off `capability`, and this label must never be the more reassuring of the two.
  const writes = safety.externalWrites || capability.canSend || capability.canSchedule;

  return (
    <Section
      id="settings-account"
      title="Google account"
      pill={
        source.live ? (
          <Pill tone="ok">Connected</Pill>
        ) : (
          <Pill tone="warn">Not connected</Pill>
        )
      }
      detail="Reads your mail, calendar and tasks. Sending and scheduling always ask first."
      change={<ChangeHint what="Connect, reconnect or change what Google grants" />}
    >
      <Field label="Access">
        <span className="settings__strong">{writes ? "Read + write" : "Read only"}</span>
        <span className="settings__quote">{safety.label}</span>
      </Field>
      <Field label="This grant can">
        <ul className="settings__caps">
          {/* Every grant reads; it is the floor the engine was built on, not a permission. */}
          <Cap on>Read mail, calendar and tasks</Cap>
          <Cap on={capability.canReadBody}>Open a whole email — stays on this Mac</Cap>
          <Cap on={capability.canSend}>Send mail you've reviewed</Cap>
          <Cap on={capability.canSchedule}>Add events to your calendar</Cap>
          <Cap on={capability.canReschedule}>Move events you already have</Cap>
        </ul>
      </Field>
    </Section>
  );
}

function CalendarsSection({ calendars }: { calendars: CalendarSummary[] | null }) {
  const planning = calendars?.filter((c) => c.role === "planning").length ?? 0;
  const excluded = (calendars?.length ?? 0) - planning;

  return (
    <Section
      id="settings-calendars"
      title="Calendar roles"
      count={calendars ? `${planning} planning · ${excluded} excluded` : undefined}
      detail="Only Planning calendars count toward your day, your free time and conflicts. Excluded ones are never read into a plan."
      change={<ChangeHint what="Mark a calendar Planning or Excluded" />}
    >
      {calendars === null ? (
        <p className="settings__note">Couldn't read the calendar list just now. The rest of this page is current.</p>
      ) : calendars.length === 0 ? (
        <p className="settings__note">No calendars yet. Connect Google, then refresh roles in the app.</p>
      ) : (
        <ul className="settings__list">
          {calendars.map((c) => (
            <li key={c.id} className="settings__listrow">
              <span className="settings__listname">{c.title}</span>
              {c.role === "planning" ? (
                <Pill tone="accent">Planning</Pill>
              ) : (
                <Pill tone="muted">Excluded</Pill>
              )}
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

function DraftingSection({ assist, capability }: { assist?: Assist; capability: Capability }) {
  const on = assist?.enabled === true;
  const provider = on && assist?.provider ? assist.provider : null;
  const leaves = on && assist?.contentLeavesMachine === true;
  const writes = capability.canSend || capability.canSchedule;

  return (
    <Section
      id="settings-drafting"
      title="AI drafting"
      pill={on ? <Pill tone="accent">On</Pill> : <Pill tone="muted">Off</Pill>}
      detail={
        on
          ? "Proposes replies and summaries when you ask. It never sends — a draft opens in the composer for you."
          : "No assistant was found on this Mac, so nothing proposes replies or summaries."
      }
      change={
        <p className="settings__change">
          Detected, not configured: drafting uses the Claude Code CLI when it's installed on this
          Mac. Install or remove it to change this.
        </p>
      }
    >
      <Field label="Provider">
        <span className="settings__strong">{provider ?? "None"}</span>
      </Field>
      <Field label="Can">
        <ul className="settings__caps">
          <Cap on={capability.canDraft}>Propose a reply</Cap>
          <Cap on={capability.canSummarize}>Summarise an email</Cap>
        </ul>
      </Field>

      <div className="settings__leaves" aria-labelledby="settings-leaves-title">
        <div id="settings-leaves-title" className="settings__leavestitle">
          What leaves this Mac
        </div>
        <dl className="settings__leaveslist">
          <dt>To Google</dt>
          <dd>
            {writes
              ? "Only what you send or schedule, after you press the button."
              : "Nothing. This connection can read, not write."}
          </dd>
          <dt>{provider ? `To ${provider}` : "To an assistant"}</dt>
          <dd>
            {!on
              ? "Nothing — there is no assistant."
              : leaves
                ? `The message you ask for a draft against${
                    capability.canSummarize ? ", and an email's body when you ask for a summary" : ""
                  }. Only on request, one message at a time. Mail marked private is never sent.`
                : "Nothing. The assistant runs on this Mac."}
          </dd>
          <dt>Stays here</dt>
          <dd>Whole emails you open, your calendar roles, your vault folder and your Google sign-in.</dd>
        </dl>
        {on && assist?.label && <p className="settings__quote">{assist.label}</p>}
      </div>
    </Section>
  );
}

function RankingSection() {
  return (
    <Section
      id="settings-ranking"
      title="Inbox ranking"
      pill={<Pill tone="muted">Built-in</Pill>}
      detail="How Mail and the Digest order your inbox. Four kinds of message jump the queue; everything else sits in topic order."
      change={
        <p className="settings__change">
          Not editable yet. The engine ranks with its built-in profile; reordering topics and
          editing the phrases will live in <MenuPath inline /> when it ships.
        </p>
      }
    >
      <div className="settings__subhead">Read first</div>
      <ul className="settings__list">
        {TRIAGE_OVERRIDES.map((o) => (
          <li key={o.headline} className="settings__listrow settings__listrow--stack">
            <span className="settings__listname">
              <span className="settings__override">Urgent</span>
              {o.headline}
            </span>
            <span className="settings__listmeta">{o.examples}</span>
          </li>
        ))}
      </ul>

      <div className="settings__subhead">Then, in this order</div>
      <ol className="settings__list settings__ranked">
        {TRIAGE_TOPICS.map((t, i) => (
          <li key={t.name} className="settings__listrow">
            <span className="settings__rank num" aria-hidden="true">
              {i + 1}
            </span>
            <span className="settings__swatch" style={{ background: topicColorVar(t.color) }} aria-hidden="true" />
            <span className="settings__listname">{t.name}</span>
            <span className="settings__listmeta">{t.covers}</span>
          </li>
        ))}
      </ol>
      <p className="settings__note">Promotions, social and spam are held back and shown as a count.</p>
    </Section>
  );
}

function ScansSection({ scanTimes, vaultSelected }: { scanTimes: string[]; vaultSelected: boolean }) {
  const times = scanTimes.map(formatTime).filter(Boolean);
  return (
    <Section
      id="settings-scans"
      title="Scans & vault"
      detail="When the planner re-reads your accounts, and whether it may use your notes folder."
      change={<ChangeHint what="Choose or forget the vault folder" />}
    >
      <Field label="Scans at">
        {times.length > 0 ? (
          <span className="settings__times">
            {times.map((t) => (
              <span key={t} className="settings__time num">
                {t}
              </span>
            ))}
          </span>
        ) : (
          <span className="settings__muted">No scheduled scans</span>
        )}
      </Field>
      <Field label="Vault folder">
        {vaultSelected ? (
          <span className="settings__strong">Allowed</span>
        ) : (
          <span className="settings__muted">Not chosen</span>
        )}
        {/* The location is never shown or sent: the engine reports only whether one is set. */}
        <span className="settings__muted">Its location is kept private to the app.</span>
      </Field>
    </Section>
  );
}

function ShortcutsSection() {
  return (
    <Section
      id="settings-shortcuts"
      title="Keyboard shortcuts"
      detail="Single keys act on the row that has focus. Nothing irreversible has a one-key shortcut."
    >
      <ul className="settings__list">
        {SHORTCUTS.map((s) => (
          <li key={s.id} className="settings__listrow">
            <span className="settings__keys">
              {s.keys.map((k) => (
                <kbd key={k} className="settings__kbd">{keyLabel(k)}</kbd>
              ))}
            </span>
            <span className="settings__listname">{s.does}</span>
            <span className="settings__listmeta">{SCOPE_TITLE[s.scope]}</span>
          </li>
        ))}
      </ul>
    </Section>
  );
}

function AboutSection({ health }: { health: Health | null }) {
  return (
    <Section id="settings-about" title="About">
      <Field label="Web interface">
        <span className="num">{WEB_VERSION}</span>
      </Field>
      <Field label="Engine">
        {health ? (
          <>
            <span className="settings__strong">{health.ok ? "Running" : "Reporting a problem"}</span>
            <span className="settings__muted num">{health.mode}</span>
          </>
        ) : (
          <span className="settings__muted">Didn't answer a health check</span>
        )}
      </Field>
      <p className="settings__note">The app's own version is in Daily Planner › About Daily Planner.</p>
    </Section>
  );
}

// ---- Pieces -------------------------------------------------------------------

function Section({
  id,
  title,
  pill,
  count,
  detail,
  change,
  children,
}: {
  id: SectionId;
  title: string;
  pill?: ReactNode;
  count?: string;
  detail?: string;
  change?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section id={id} className="sset" aria-labelledby={`${id}-title`}>
      <div className="sset__head">
        <h2 id={`${id}-title`} className="sset__title">
          {title}
        </h2>
        {pill}
        {count && <span className="sset__count num">{count}</span>}
      </div>
      {detail && <p className="sset__detail">{detail}</p>}
      <div className="sset__body">{children}</div>
      {change && <div className="sset__foot">{change}</div>}
    </section>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="sfield">
      <div className="sfield__label">{label}</div>
      <div className="sfield__value">{children}</div>
    </div>
  );
}

function Cap({ on, children }: { on: boolean; children: ReactNode }) {
  return (
    <li className={`settings__cap${on ? " settings__cap--on" : ""}`}>
      <span className="settings__capmark" aria-hidden="true">
        {on ? <CheckIcon /> : <DashIcon />}
      </span>
      <span>{children}</span>
      <span className="sr-only">{on ? "— yes" : "— no"}</span>
    </li>
  );
}

type Tone = "ok" | "warn" | "accent" | "muted";

function Pill({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <span className={`spill spill--${tone}`}>{children}</span>;
}

/**
 * Where the change is made. Not a button: this page cannot open the native window, and a
 * button that does nothing is a lie told with a hover state.
 */
function ChangeHint({ what }: { what: string }) {
  return (
    <p className="settings__change">
      {what} in <MenuPath inline />
    </p>
  );
}

function MenuPath({ inline = false }: { inline?: boolean }) {
  return (
    <>
      <span className="settings__menupath">
        <span className="settings__menu">Daily Planner › Settings…</span>
        <span className="settings__kbd settings__kbd--sm">⌘,</span>
      </span>
      {inline ? "" : "."}
    </>
  );
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.8">
      <path d="M3.5 8.5l3 3 6-7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function DashIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M4.5 8h7" strokeLinecap="round" />
    </svg>
  );
}
