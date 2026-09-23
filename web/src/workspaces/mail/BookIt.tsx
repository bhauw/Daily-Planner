/*
 * BookIt — offering to put a meeting in the calendar, from the email that proposes it.
 *
 * Two triggers, one row. A date or time seen in the email is offered quietly ("Dates in this
 * email"); once he drafts an ACCEPT, the same row asks outright, because agreeing to a coffee
 * chat and then forgetting to book it is the thing this exists to stop.
 *
 * It never books anything itself. Every button opens the existing scheduler, prefilled, where
 * he sees the title and times and confirms — the same single write path as everywhere else.
 * The times come from `meetingTime.ts`, which reads the text already on screen and sends none
 * of it anywhere.
 */

import { useMemo } from "react";
import { useWriteDesk } from "../../compose/WriteDesk";
import { findMeetingTimes, titleFromSubject, DEFAULT_MINUTES, type MeetingTime } from "./meetingTime";

export function BookIt({
  text,
  subject,
  receivedAt,
  accepted,
}: {
  /** The email as shown — the full body when it loaded, the preview otherwise. */
  text: string;
  subject: string;
  receivedAt: string | null | undefined;
  /** Whether he has just drafted a reply agreeing to it. */
  accepted: boolean;
}) {
  const desk = useWriteDesk();
  const found = useMemo(
    () => findMeetingTimes(`${subject}\n${text}`, receivedAt ? new Date(receivedAt) : new Date()),
    [subject, text, receivedAt],
  );

  // No calendar grant, no offer: a button that cannot book is the button-and-grant disagreement
  // the write desk exists to prevent.
  if (!desk?.capability.canSchedule) return null;
  if (found.length === 0 && !accepted) return null;

  const title = titleFromSubject(subject);

  function book(time: MeetingTime | null) {
    const start = time?.start ?? nextHour();
    const end = time?.end ?? new Date(start.getTime() + DEFAULT_MINUTES * 60_000);
    desk!.schedule({
      title,
      start: start.toISOString(),
      end: end.toISOString(),
      context: time
        ? `From the email: “${time.source}”${time.hasTime ? "" : " — no time was given, so check it."}`
        : "No date was found in the email. Pick the time you agreed.",
    });
  }

  return (
    <div
      className={["bookit", accepted ? "bookit--prompt" : ""].filter(Boolean).join(" ")}
      role="group"
      aria-label="Add to calendar"
    >
      <span className="bookit__label">
        {accepted ? "You’re accepting — put it in your calendar?" : "Dates in this email"}
      </span>
      <div className="bookit__options">
        {found.map((time) => (
          <button
            key={time.start.toISOString()}
            type="button"
            className="compose__chip"
            title={`Found: “${time.source}”`}
            onClick={() => book(time)}
          >
            Add {label(time)}
          </button>
        ))}
        {accepted && (
          <button type="button" className="compose__chip" onClick={() => book(null)}>
            {found.length ? "Another time…" : "Add to calendar…"}
          </button>
        )}
      </div>
    </div>
  );
}

function label(time: MeetingTime): string {
  const day = time.start.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  if (!time.hasTime) return `${day} (no time given)`;
  const at = time.start.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `${day} · ${at}`;
}

function nextHour(): Date {
  const d = new Date();
  d.setHours(d.getHours() + 1, 0, 0, 0);
  return d;
}
