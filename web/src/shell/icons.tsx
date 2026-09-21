/*
 * Line glyphs for the sidebar rail and safety rail, ported from the approved
 * nav-options.html. All are decorative (aria-hidden); the nav item's text is the
 * accessible name. 16x16 on a 1.5 stroke to match the mockup.
 */

import type { SVGProps } from "react";

type Glyph = (props: SVGProps<SVGSVGElement>) => JSX.Element;

function base(children: JSX.Element): Glyph {
  return (props: SVGProps<SVGSVGElement>) => (
    <svg
      className="glyph"
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...props}
    >
      {children}
    </svg>
  );
}

export const TodayIcon = base(
  <>
    <rect x="2" y="3" width="12" height="11" rx="2" />
    <path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" />
  </>,
);

export const FocusIcon = base(
  <>
    <path d="M8 2v6l4 2" />
    <circle cx="8" cy="8" r="6" />
  </>,
);

export const DigestIcon = base(<path d="M2 4h12M2 8h12M2 12h7" />);

export const MailIcon = base(
  <>
    <rect x="2" y="3.5" width="12" height="9" rx="2" />
    <path d="m2.5 5 5.5 4 5.5-4" />
  </>,
);

export const CalendarIcon = base(
  <>
    <rect x="2" y="3" width="12" height="11" rx="2" />
    <path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" />
  </>,
);

export const TasksIcon = base(
  <>
    <path d="M3 8.5 6 11l7-7" />
    <path d="M3 13h10" />
  </>,
);

export const SettingsIcon = base(
  <>
    <circle cx="8" cy="8" r="2.5" />
    <path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2" />
  </>,
);

export const LockIcon = base(
  <>
    <rect x="3" y="7" width="10" height="7" rx="1.5" />
    <path d="M5 7V5a3 3 0 0 1 6 0v2" />
  </>,
);

/* The same padlock with its shackle open. Shown when the engine can actually send or schedule:
   a closed lock over an app that writes to someone's account is the picture version of a claim
   that is no longer true. */
export const UnlockIcon = base(
  <>
    <rect x="3" y="7" width="10" height="7" rx="1.5" />
    <path d="M5 7V5a3 3 0 0 1 6 0" />
  </>,
);
