/*
 * The draft action state machine. Pinned: every legal transition, every illegal one refused
 * (returned unchanged), and the invariant the whole workbench rests on — nothing reaches
 * `approved` except `approve` from `preflighted`, and any payload change after approval sends
 * the draft back through preflight. The last block walks every event sequence up to a fixed
 * depth, so a new shortcut to approval fails here even if no hand-written case anticipated it.
 */

import { describe, expect, it } from "vitest";
import {
  approve,
  canApprove,
  canPreflight,
  editBody,
  editSubject,
  initialState,
  preflight,
  reject,
  statusLabel,
  type DraftState,
  type DraftStatus,
} from "./machine";

const ALL: DraftStatus[] = ["proposed", "edited", "preflighted", "approved", "rejected"];

function at(status: DraftStatus, approvalRevoked = false): DraftState {
  return { status, subject: "Re: Lab 3", body: "Thursday works.", approvalRevoked };
}

/** Drive a fresh draft to `status` through the machine itself, not by constructing it. */
function reach(status: DraftStatus): DraftState {
  const s0 = initialState("Re: Lab 3", "Thursday works.");
  switch (status) {
    case "proposed":
      return s0;
    case "edited":
      return editBody(s0, "Thursday works for me.");
    case "preflighted":
      return preflight(s0);
    case "approved":
      return approve(preflight(s0));
    case "rejected":
      return reject(s0);
  }
}

describe("initialState", () => {
  it("starts proposed, with the payload as given and no revoked approval", () => {
    expect(initialState("Subj", "Body")).toEqual({
      status: "proposed",
      subject: "Subj",
      body: "Body",
      approvalRevoked: false,
    });
  });

  it("is the reset: a fresh draft carries nothing over from an approved or rejected one", () => {
    // The workbench re-seeds a draft with initialState; there is no reset event that could
    // resurrect an approval or a rejection.
    const fresh = initialState("Re: Lab 3", "Thursday works.");
    expect(fresh.status).toBe("proposed");
    expect(fresh.approvalRevoked).toBe(false);
    expect(canApprove(fresh)).toBe(false);
  });
});

describe("legal transitions", () => {
  it("proposed → edited on a subject change", () => {
    const s = editSubject(reach("proposed"), "Re: Lab 3 (updated)");
    expect(s.status).toBe("edited");
    expect(s.subject).toBe("Re: Lab 3 (updated)");
    expect(s.approvalRevoked).toBe(false);
  });

  it("proposed → edited on a body change", () => {
    const s = editBody(reach("proposed"), "Friday instead?");
    expect(s.status).toBe("edited");
    expect(s.body).toBe("Friday instead?");
    expect(s.approvalRevoked).toBe(false);
  });

  it("edited stays edited on further edits", () => {
    const s = editSubject(editBody(reach("edited"), "again"), "new subject");
    expect(s.status).toBe("edited");
    expect(s.approvalRevoked).toBe(false);
  });

  it("proposed → preflighted", () => {
    expect(preflight(reach("proposed")).status).toBe("preflighted");
  });

  it("edited → preflighted", () => {
    expect(preflight(reach("edited")).status).toBe("preflighted");
  });

  it("preflighted → approved", () => {
    const s = approve(reach("preflighted"));
    expect(s.status).toBe("approved");
    expect(s.approvalRevoked).toBe(false);
  });

  it("preflighted → edited on a payload change: the edit must be preflighted again", () => {
    const s = editBody(reach("preflighted"), "changed after preflight");
    expect(s.status).toBe("edited");
    expect(canApprove(s)).toBe(false);
    // Nothing had been approved, so nothing was revoked.
    expect(s.approvalRevoked).toBe(false);
  });

  it.each(["proposed", "edited", "preflighted", "approved"] as const)("%s → rejected", (from) => {
    const before = reach(from);
    const s = reject(before);
    expect(s.status).toBe("rejected");
    expect(s.subject).toBe(before.subject);
    expect(s.body).toBe(before.body);
  });
});

describe("approval revocation", () => {
  it.each([
    ["subject", (s: DraftState) => editSubject(s, "Different subject")],
    ["body", (s: DraftState) => editBody(s, "Different body")],
  ])("a %s change after approval returns to edited and revokes it", (_, edit) => {
    const s = edit(reach("approved"));
    expect(s.status).toBe("edited");
    expect(s.approvalRevoked).toBe(true);
    expect(canApprove(s)).toBe(false);
  });

  it("the revoke notice survives further edits and preflight, and clears only on re-approval", () => {
    let s = editBody(reach("approved"), "one");
    s = editSubject(s, "two");
    expect(s.approvalRevoked).toBe(true);
    s = preflight(s);
    expect(s.status).toBe("preflighted");
    expect(s.approvalRevoked).toBe(true);
    s = approve(s);
    expect(s.status).toBe("approved");
    expect(s.approvalRevoked).toBe(false);
  });

  it("an edit back to the approved text still revokes — the check is 'changed', not 'different from approved'", () => {
    const approved = reach("approved");
    const s = editBody(editBody(approved, "tweak"), approved.body);
    expect(s.status).toBe("edited");
    expect(s.approvalRevoked).toBe(true);
  });

  it("an edit that changes nothing is not an edit: approval stands and the same object comes back", () => {
    const approved = reach("approved");
    expect(editBody(approved, approved.body)).toBe(approved);
    expect(editSubject(approved, approved.subject)).toBe(approved);
  });
});

describe("illegal transitions are refused (state returned unchanged)", () => {
  it.each(["proposed", "edited", "approved", "rejected"] as const)(
    "approve from %s is refused — approval only follows preflight",
    (from) => {
      const s = reach(from);
      expect(approve(s)).toBe(s);
    },
  );

  it.each(["preflighted", "approved", "rejected"] as const)("preflight from %s is refused", (from) => {
    const s = reach(from);
    expect(preflight(s)).toBe(s);
  });

  it("there is no proposed → approved shortcut", () => {
    expect(approve(reach("proposed")).status).toBe("proposed");
  });

  it("there is no edited → approved shortcut", () => {
    expect(approve(reach("edited")).status).toBe("edited");
  });

  it("approving twice does not change an approved draft", () => {
    const s = reach("approved");
    expect(approve(s)).toBe(s);
  });

  it("a revoked approval cannot be restored by approve without a fresh preflight", () => {
    const s = editBody(reach("approved"), "changed");
    expect(approve(s)).toBe(s);
    expect(s.status).toBe("edited");
  });
});

describe("rejected is terminal this round", () => {
  it("refuses preflight and approve", () => {
    const s = reach("rejected");
    expect(preflight(s)).toBe(s);
    expect(approve(s)).toBe(s);
  });

  it("refuses payload edits — the text of a rejected draft does not change", () => {
    const s = reach("rejected");
    expect(editSubject(s, "sneaky subject")).toBe(s);
    expect(editBody(s, "sneaky body")).toBe(s);
  });

  it("rejecting again stays rejected", () => {
    expect(reject(reach("rejected")).status).toBe("rejected");
  });

  it("offers neither control", () => {
    const s = reach("rejected");
    expect(canPreflight(s)).toBe(false);
    expect(canApprove(s)).toBe(false);
  });
});

describe("control gates", () => {
  it.each(ALL)("canPreflight / canApprove agree with the transitions from %s", (status) => {
    const s = at(status);
    expect(canPreflight(s)).toBe(preflight(s) !== s);
    expect(canApprove(s)).toBe(approve(s) !== s);
  });

  it("Approve is enabled in exactly one state", () => {
    expect(ALL.filter((st) => canApprove(at(st)))).toEqual(["preflighted"]);
  });

  it("Preflight is enabled only before preflight", () => {
    expect(ALL.filter((st) => canPreflight(at(st)))).toEqual(["proposed", "edited"]);
  });
});

describe("purity", () => {
  it("no transition mutates the state it was given", () => {
    for (const status of ALL) {
      const s = Object.freeze(at(status, true));
      // Frozen: any in-place write would throw in strict mode.
      editSubject(s, "x");
      editBody(s, "y");
      preflight(s);
      approve(s);
      reject(s);
      expect(s.status).toBe(status);
    }
  });
});

describe("statusLabel", () => {
  it("labels every status", () => {
    expect(ALL.map(statusLabel)).toEqual(["Proposed", "Edited", "Preflighted", "Approved", "Rejected"]);
  });
});

// ---- Exhaustive walk ----------------------------------------------------------------------

type Event = { name: string; run: (s: DraftState) => DraftState };

// Payload edits use text derived from the state so every edit is a real change.
const EVENTS: Event[] = [
  { name: "editSubject", run: (s) => editSubject(s, s.subject + "!") },
  { name: "editBody", run: (s) => editBody(s, s.body + "!") },
  { name: "editSame", run: (s) => editBody(s, s.body) },
  { name: "preflight", run: preflight },
  { name: "approve", run: approve },
  { name: "reject", run: reject },
];

const DEPTH = 7; // 6^7 ≈ 280k sequences — covers every path through the five states several times.

describe("every event sequence up to depth " + DEPTH, () => {
  it("holds the invariants at every step", () => {
    let checked = 0;
    const walk = (s: DraftState, depth: number, path: string[]) => {
      if (depth === 0) return;
      for (const ev of EVENTS) {
        const next = ev.run(s);
        const where = [...path, ev.name].join(" → ");
        checked++;

        // 1. Approval is reached only by approve, only from preflighted.
        if (next.status === "approved" && s.status !== "approved") {
          if (ev.name !== "approve" || s.status !== "preflighted") {
            throw new Error(`reached approved without preflight+approve: ${where}`);
          }
        }
        // 2. An approved draft that changes payload is no longer approved, and says so.
        if (s.status === "approved" && (next.body !== s.body || next.subject !== s.subject)) {
          if (next.status !== "edited" || !next.approvalRevoked) {
            throw new Error(`payload changed after approval without revoking it: ${where}`);
          }
        }
        // 3. An approved draft's payload is exactly what was approved: payload never changes
        //    while the status stays approved.
        if (s.status === "approved" && next.status === "approved") {
          if (next.body !== s.body || next.subject !== s.subject) {
            throw new Error(`approved payload changed in place: ${where}`);
          }
        }
        // 4. Rejected is terminal — nothing about it changes.
        if (s.status === "rejected" && JSON.stringify(next) !== JSON.stringify(s)) {
          throw new Error(`rejected draft changed: ${where}`);
        }
        // 5. An approved draft never carries the revoke notice.
        if (next.status === "approved" && next.approvalRevoked) {
          throw new Error(`approved yet marked revoked: ${where}`);
        }

        walk(next, depth - 1, [...path, ev.name]);
      }
    };
    walk(initialState("Re: Lab 3", "Thursday works."), DEPTH, []);
    expect(checked).toBeGreaterThan(100_000);
  });
});
