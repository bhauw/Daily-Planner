/*
 * Button — the app's only button primitive. Always a real <button> with an
 * accessible name (its text, or `label` for icon-only use). Variants:
 *   - "default": quiet surface button
 *   - "primary": the accent action (one per group, max)
 *   - "ghost": text-only, for low-emphasis actions
 * Every variant meets the 44x44 target via min-height and adequate padding.
 */

import type { ButtonHTMLAttributes, ReactNode } from "react";
import "./button.css";

type Variant = "default" | "primary" | "ghost";
type Size = "sm" | "md";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  /** Required when the button has no visible text (icon-only). */
  label?: string;
  icon?: ReactNode;
  children?: ReactNode;
}

export function Button({
  variant = "default",
  size = "md",
  label,
  icon,
  children,
  className,
  type,
  ...rest
}: ButtonProps) {
  const iconOnly = icon != null && children == null;
  return (
    <button
      type={type ?? "button"}
      className={["btn", `btn--${variant}`, `btn--${size}`, iconOnly ? "btn--icon" : "", className]
        .filter(Boolean)
        .join(" ")}
      aria-label={label ?? (iconOnly ? undefined : rest["aria-label"])}
      {...rest}
    >
      {icon}
      {children != null && <span className="btn__text">{children}</span>}
    </button>
  );
}
