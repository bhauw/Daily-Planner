# Front-end pass — 2026-09-23

The first leg after the back end was declared solid. Seven test agents used the web UI against the dev mock
(Playwright driving headless Chrome at 1024, 1280, 1440 and 1920 px). Their findings were fixed on
separate branches and merged into `main`. Raw tester reports: `~/.claude/jobs/e590a56e/tmp/reports/t1…t7`.
They are temporary and get deleted with the job, so everything that matters is copied below.

**Verification on `main` after the last merge:** web **532 passed / 0 failed** (52 files), and `npm run build` is clean.
Swift **604 passed / 0 failed** (no Swift source changed in this pass).

## What landed

| Branch | What it does |
|---|---|
| `ux/lastscan` | The hardcoded "Last scan 12:00" is gone and now shows "—". The engine has no last-scan field, so it needs `lastScanAt` on `SettingsResponse` (from `GoogleDashboardSnapshot.syncedAt`). 43 tests pin `mail/machine.ts`; they found that a rejected draft could still be edited, and that is fixed. |
| `ux/keys` | Every `<kbd>` hint now does what it says (R reply, S schedule, O open), scoped to the focused row and never inside a text field. Number keys switch surfaces. `?` opens an overlay. One registry (`shell/shortcuts.ts`) is enforced by a test that scans the source. |
| `ux/visual` | The safety rail is now a neutral strip with an amber edge, on one line. Tags are sentence case on an 8% tint (worst contrast 4.62:1). There is one eyebrow style and three title sizes, plus hover, pressed and disabled tokens. Only one filled Reply per column. The Digest 40% cut-off and calendar block clipping are fixed. |
| `ux/settings` | A real read-only `/settings` page (Google grant, calendar roles, drafting and "what leaves this Mac", inbox ranking, shortcuts, version). It makes no write calls, and a test enforces that. |
| `ux/layout` | Tasks board is a responsive grid that scrolls on its own, with a fade and chevron cue. Task controls sit on one row. Sidebar hit targets are 44px. Reduced motion now stops movement but keeps colour fades. Assistant-card actions sit on one row. |
| `ux/focusfix` | "Do next" no longer treats a finished work block as overdue. Urgent mail and queue items now rank on Focus. "Put on the day" books before the deadline, in a free gap. **Sending no longer wipes the surface**: the refresh runs in the background and the answered item drops off. Bundle cards stop offering Reply. Counts are honest. No-reply senders are flagged. Esc or a backdrop click asks before discarding a reply. "Next scan" comes from the engine. |
| `ux/calfix` | The drop time shows correctly in the form. Block time and Move it check for conflicts. An approved reschedule stays put. Availability no longer offers times that have passed. Capture routing quotes the matched keyword, scores every list and asks when unsure. One clock format and one workload reading everywhere. Block time works end to end from the keyboard. The UI admits that approved task moves are local only (`tasks.readonly`). **Events that cross midnight** keep their length and show on every day they touch. |
| `ux/mailfix` | **The email always gets at least 8 readable lines at 1024 and 1280.** The reply box starts compact and grows. The reply box no longer leaks between threads. Drafting locks the field and offers Undo. Typed instructions go out as `acknowledge`, not `accept`. The drafting chips respect the assistant-off setting and say what leaves the Mac. The false "Reply needed" and send warnings are gone. Reject has Undo. ⌘↵ goes to Review. Busy states are announced to screen readers and focus is kept. |
| `ux/offertimes` | **New: Offer times.** Pick 3–5 free slots and let Claude draft a reply offering them. Only the times leave the Mac, never event titles (a test enforces this). It goes through the existing Review → Send. |
| `ux/planday` | **New: Plan my day** (`/plan`). Four steps: read urgent mail first, pick tasks and size them, fit them into free gaps (with a warning when over-committed), then review and add the calendar events in one confirm. If some events fail, each failure is reported per row with Try again. A read-only account gets Copy plan instead. Block time in Tasks now creates a real event after you confirm. |
| `ux/prepcard` | **New: prep and follow-through card** for coffee chats and interviews. It shows time, place, the related thread and prep tasks. Within 48h after the event ends it switches to "Draft thank-you", and the prompt sends nothing from your calendar. |
| `ux/a11y` | Accessibility fixes: focus after the composer's phase change, list roles, an `<h1>` per route, done-task contrast, the safety rail as a landmark, a 200% zoom fallback, and target sizes. |

## Still open, ranked

### Needs your decision
1. **The opened email is the middle pane's one scroller.** `mail.css` notes you allowed this on 2026-09-22. Confirm it's still OK. When the email is closed nothing scrolls, and the thread list is still the only scroller by default.
2. **Tasks write access.** Real capture, moves and ticking tasks done need the `tasks` scope, which means reconnecting Google. Until then the UI says "saved locally only".
3. **Mis-ranked inbox.** Still unanswered. The TriageProfile is wired but still runs with its default settings.

### Bugs and polish that were found but not fixed
- Plan my day's tags still use the old outlined all-caps style, and its Reply is still primary on no-reply mail.
- At 1024px the page still scrolls sideways a little, because of the safety rail's minimum width.
- Composer footer (Cancel/Review) can sit below the fold at 1440 and smaller.
- RTL locations get scrambled in Dayline rows (they need `<bdi>`). Long unbroken URLs clip in Dayline titles.
- Load failures (500, 401, offline) all show the same generic error. Mail failures, by contrast, show a specific message for each cause.
- Excluded "Work" events disappear from the Calendar with no indicator. The empty Tasks list has no empty-state text.
- Calendar availability slots don't open the scheduler yet. Plan blocks go to the primary calendar.
- The prep card's mock interview uses the real clock, not the mock day, so it looks odd in dev only.

### Product backlog (from the product review, not built)
| # | Feature | Backend | Effort | Impact |
|---|---|---|---|---|
| P7 | Week conflicts & load check (interview vs midterm) with Move it / Ask to reschedule | none | S–M | 4 |
| P5 | Waiting-on list: sent threads with no reply after N days, plus Draft a nudge | SENT read + route + dismiss state | M | 4 |
| P6 | Triage profile editor in Settings (describe yourself, Claude proposes topics) | persistence + GET/PUT + propose route | M–L | 4 |
| P12 | "Brief me": summarise the top 5 must-read emails | none (loop summarise) | S | 3 |
| P9 | End-of-day shutdown + weekly review, "Copy recap" | none for v1 | M | 3 |
| P8 | ⌘K command bar (shortcuts are done; this is the jump-anywhere part) | none | S | 3 |
| P11 | Real tasks write-back | `tasks` scope, re-consent | L | 4 |
| P10 | Recruiting pipeline lens (read-only, overlaps RECRUIT) | store | M–L | 3 |

**Recommended next:** P7 week conflicts (no backend work, and the mock already contains the conflict), then P12 Brief me, then P5 Waiting-on.

## Housekeeping
- The installed app in `/Applications` does **not** have any of this yet. Run the Swift suite, then `build-app.sh` and `install-app.sh`, then quit and relaunch.
- 12 `ux/*` branches and their worktrees in `.claude/worktrees/` can be removed once you're happy.
