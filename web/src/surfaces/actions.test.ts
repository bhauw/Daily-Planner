/*
 * The action set is where the interaction rules actually live, so they are
 * asserted here rather than left to a component that happens to render them.
 */

import { describe, expect, it } from "vitest";
import type { Draft, PlannerEvent, TaskItem } from "../api/client";
import {
  NO_WRITES,
  calendarDayURL,
  calendarTemplateURL,
  defaultBlock,
  eventActions,
  gmailSearchURL,
  isExternalWrite,
  replyActions,
  replySubject,
  taskActions,
  type ActionCapability,
} from "./actions";

const CAN_WRITE: ActionCapability = { canSend: true, canSchedule: true };

const event: PlannerEvent = {
  id: "e1",
  title: "ECON 295 · Managerial Economics",
  category: "school",
  kind: "event",
  start: "2026-09-16T11:00:00-07:00",
  end: "2026-09-16T12:30:00-07:00",
  due: null,
  location: "Henry Angus 098",
};

const draft: Draft = {
  id: "d1",
  title: "Re: Lease Bonuses",
  summary: "Hello Braxton, I checked your record",
  kind: "reply",
  sender: "leasing@example.test",
  receivedAt: "2026-09-16T09:00:00-07:00",
};

const task: TaskItem = {
  id: "t1",
  title: "Look at ORCA and how to take quiz",
  category: "school",
  due: "2026-09-16T19:00:00-07:00",
  done: false,
};

describe("every item offers something that works right now", () => {
  it("gives every row at least one action", () => {
    for (const actions of [
      eventActions(event, NO_WRITES),
      replyActions(draft, NO_WRITES),
      taskActions(task, NO_WRITES),
    ]) {
      expect(actions.length).toBeGreaterThan(0);
    }
  });

  it("gives each item exactly one primary action", () => {
    for (const actions of [
      eventActions(event, CAN_WRITE),
      replyActions(draft, CAN_WRITE),
      taskActions(task, CAN_WRITE),
    ]) {
      expect(actions.filter((a) => a.primary)).toHaveLength(1);
    }
  });

  it("labels every action, because an unnamed control is a guessing game", () => {
    for (const actions of [
      eventActions(event, CAN_WRITE),
      replyActions(draft, CAN_WRITE),
      taskActions(task, CAN_WRITE),
    ]) {
      for (const action of actions) {
        expect(action.label.trim().length).toBeGreaterThan(0);
      }
    }
  });

  it("keeps shortcuts unique within an item, so one key means one thing", () => {
    for (const actions of [
      eventActions(event, CAN_WRITE),
      replyActions(draft, CAN_WRITE),
      taskActions(task, CAN_WRITE),
    ]) {
      const keys = actions.map((a) => a.shortcut).filter(Boolean);
      expect(new Set(keys).size).toBe(keys.length);
    }
  });
});

describe("no action is ever a dead end", () => {
  it("leaves nothing unavailable, at either capability", () => {
    // The rule that matters: pressing a row must always lead somewhere. Without
    // write scopes the write actions hand off to Google's own prefilled compose
    // and event screens rather than greying themselves out.
    for (const capability of [NO_WRITES, CAN_WRITE]) {
      for (const actions of [
        eventActions(event, capability),
        replyActions(draft, capability),
        taskActions(task, capability),
      ]) {
        for (const action of actions) expect(action.unavailable).toBeUndefined();
      }
    }
  });

  it("gives every write action somewhere to go at EITHER capability", () => {
    // The rule this file exists for, restated now that there are two ways to satisfy it: with
    // write scopes an action carries a prefill and opens the app's own composer; without them
    // it carries an href to Google's. An action with neither is a button that does nothing —
    // and it would pass every other assertion here.
    for (const capability of [NO_WRITES, CAN_WRITE]) {
      const writes = [
        ...eventActions(event, capability),
        ...replyActions(draft, capability),
        ...taskActions(task, capability),
      ].filter(isExternalWrite);

      expect(writes.length).toBeGreaterThan(0);
      for (const action of writes) {
        expect(
          Boolean(action.href) || Boolean(action.compose) || Boolean(action.schedule),
        ).toBe(true);
      }
    }
  });

  it("sends the reply in-app when it can, and hands off only when it cannot", () => {
    const inApp = replyActions(draft, CAN_WRITE).find((a) => a.id === "reply")!;
    expect(inApp.compose).toBeDefined();
    expect(inApp.compose!.to).toEqual(["leasing@example.test"]);
    expect(inApp.compose!.subject).toBe("Re: Lease Bonuses");
    // No Gmail link on the in-app path: the row must not quietly open a tab as well.
    expect(inApp.href).toBeUndefined();

    const handoff = replyActions(draft, NO_WRITES).find((a) => a.id === "reply")!;
    expect(handoff.compose).toBeUndefined();
    expect(handoff.href).toContain("mail.google.com");
  });

  it("threads the reply into the conversation it answers", () => {
    // Without this the reply is a new message that merely shares a subject — which is what
    // shipped for as long as the thread id was read from Gmail and then dropped on the floor.
    const threaded = replyActions({ ...draft, threadId: "t-42" }, CAN_WRITE).find((a) => a.id === "reply")!;
    expect(threaded.compose!.threadId).toBe("t-42");

    // Sample data has no thread, and must not invent one.
    const untreaded = replyActions(draft, CAN_WRITE).find((a) => a.id === "reply")!;
    expect(untreaded.compose!.threadId).toBeUndefined();
  });

  it("will not open a composer with no one to send to", () => {
    // A draft with no sender has no address to answer. Offering an in-app composer with an
    // empty To field is worse than offering to find the thread in Gmail.
    const senderless = replyActions({ ...draft, sender: undefined }, CAN_WRITE).find((a) => a.id === "reply")!;
    expect(senderless.compose).toBeUndefined();
    expect(senderless.href).toBeTruthy();
    expect(senderless.label).toBe("Reply in Gmail");
  });

  it("schedules in-app with the times already filled in", () => {
    const block = taskActions(task, CAN_WRITE).find((a) => a.id === "schedule-task")!;
    expect(block.schedule).toBeDefined();
    expect(block.schedule!.title).toBe(task.title);
    expect(new Date(block.schedule!.end).getTime()).toBeGreaterThan(
      new Date(block.schedule!.start).getTime(),
    );

    const move = eventActions(event, CAN_WRITE).find((a) => a.id === "reschedule")!;
    expect(move.schedule!.start).toBe(event.start);
    expect(move.schedule!.end).toBe(event.end);
  });

  it("gives every write action somewhere to go when the app cannot do it in-house", () => {
    const writes = [
      ...eventActions(event, NO_WRITES),
      ...replyActions(draft, NO_WRITES),
      ...taskActions(task, NO_WRITES),
    ].filter(isExternalWrite);

    expect(writes.length).toBeGreaterThan(0);
    for (const action of writes) expect(action.href).toBeTruthy();
  });

  it("says where it is taking you when it hands off, and stops saying so when it does not", () => {
    expect(replyActions(draft, NO_WRITES).find((a) => a.id === "reply")!.label).toBe("Reply in Gmail");
    expect(replyActions(draft, CAN_WRITE).find((a) => a.id === "reply")!.label).toBe("Reply");
  });

  it("prefills the compose window with the sender and a sane reply subject", () => {
    const reply = replyActions(draft, NO_WRITES).find((a) => a.id === "reply")!;
    expect(reply.href).toContain("to=leasing%40example.test");
    expect(reply.href).toContain("su=Re%3A+Lease+Bonuses");
  });

  it("does not stack Re: on a subject that already has one", () => {
    expect(replySubject("Re: Lease Bonuses")).toBe("Re: Lease Bonuses");
    expect(replySubject("Lease Bonuses")).toBe("Re: Lease Bonuses");
    expect(replySubject("RE: shouting")).toBe("RE: shouting");
  });

  it("builds a calendar template with UTC basic-format timestamps", () => {
    const url = calendarTemplateURL({
      title: "Deep work",
      start: new Date("2026-09-16T18:00:00Z"),
      end: new Date("2026-09-16T19:00:00Z"),
    });
    expect(url).toContain("action=TEMPLATE");
    expect(url).toContain("dates=20260916T180000Z%2F20260916T190000Z");
  });

  it("blocks a task into the next whole hour", () => {
    const { start, end } = defaultBlock(new Date("2026-09-16T11:17:00Z"));
    expect(start.toISOString()).toBe("2026-09-16T12:00:00.000Z");
    expect(end.toISOString()).toBe("2026-09-16T13:00:00.000Z");
  });

  it("classifies exactly the effects that leave this machine as writes", () => {
    expect(isExternalWrite({ id: "x", label: "x", effect: "compose" })).toBe(true);
    expect(isExternalWrite({ id: "x", label: "x", effect: "schedule" })).toBe(true);
    expect(isExternalWrite({ id: "x", label: "x", effect: "open" })).toBe(false);
    expect(isExternalWrite({ id: "x", label: "x", effect: "copy" })).toBe(false);
  });
});

describe("links point where the user expects", () => {
  it("opens the calendar on the event's own day", () => {
    expect(calendarDayURL(event.start)).toBe(
      "https://calendar.google.com/calendar/u/0/r/day/2026/9/16",
    );
  });

  it("returns nothing for an unparseable date rather than a broken link", () => {
    expect(calendarDayURL("not-a-date")).toBeUndefined();
  });

  it("drops the calendar action entirely when the date cannot be read", () => {
    const broken = eventActions({ ...event, start: "not-a-date" }, CAN_WRITE);
    expect(broken.find((a) => a.id === "open-calendar")).toBeUndefined();
    // Still usable: copy survives.
    expect(broken.some((a) => !a.unavailable)).toBe(true);
  });

  it("escapes a subject so search survives punctuation", () => {
    expect(gmailSearchURL("Re: Lease Bonuses")).toBe(
      "https://mail.google.com/mail/u/0/#search/Re%3A%20Lease%20Bonuses",
    );
  });

  it("omits copy-address when there is no sender to copy", () => {
    const actions = replyActions({ ...draft, sender: undefined }, CAN_WRITE);
    expect(actions.find((a) => a.id === "copy-sender")).toBeUndefined();
  });
});
