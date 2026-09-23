/*
 * "?" opens the list of every key; number keys walk the rail.
 *
 * The overlay is a modal, so it is held to the write desk's guarantees: Esc closes, Tab stays
 * in, the app behind is inert, focus goes back where it was. And the global keys obey the same
 * rule as every other: a digit typed into a field is a digit.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { KeyboardShortcuts } from "./KeyboardShortcuts";
import { NAV_KEYS, SHORTCUTS, keyLabel } from "./shortcuts";

let host: HTMLElement;
let root: Root;
const navigate = vi.fn();

function Harness() {
  const [open, setOpen] = useState(false);
  const appRef = useRef<HTMLDivElement>(null);
  return createElement(
    "div",
    null,
    createElement(
      "div",
      { ref: appRef, id: "app" },
      createElement("button", { id: "behind" }, "Something on the page"),
      createElement("input", { id: "field" }),
    ),
    createElement(KeyboardShortcuts, { open, onOpenChange: setOpen, onNavigate: navigate, backgroundRef: appRef }),
  );
}

async function mount() {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root.render(createElement(Harness));
  });
}

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  navigate.mockClear();
});

async function press(key: string, init: KeyboardEventInit = {}) {
  const target = (document.activeElement as HTMLElement | null) ?? document.body;
  await act(async () => {
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

const dialog = () => host.querySelector<HTMLElement>('[role="dialog"]');

describe("the shortcut overlay", () => {
  it("opens on ?, as a labelled modal that lists every registry entry", async () => {
    await mount();
    host.querySelector<HTMLElement>("#behind")!.focus();

    await press("?", { shiftKey: true });

    const d = dialog();
    expect(d).not.toBeNull();
    expect(d!.getAttribute("aria-modal")).toBe("true");
    expect(host.querySelector(`#${d!.getAttribute("aria-labelledby")}`)?.textContent).toBe("Keyboard shortcuts");
    for (const s of SHORTCUTS) expect(d!.textContent).toContain(s.does);
    for (const key of SHORTCUTS.flatMap((s) => s.keys)) expect(d!.textContent).toContain(keyLabel(key));
    expect(host.querySelector("#app")!.hasAttribute("inert")).toBe(true);
  });

  it("closes on Esc and puts focus back where it was", async () => {
    await mount();
    const behind = host.querySelector<HTMLElement>("#behind")!;
    behind.focus();
    await press("?");
    expect(document.activeElement).toBe(dialog());

    await press("Escape");

    expect(dialog()).toBeNull();
    expect(host.querySelector("#app")!.hasAttribute("inert")).toBe(false);
    expect(document.activeElement).toBe(behind);
  });

  it("closes on ? as well, and from its Close button", async () => {
    await mount();
    await press("?");
    await press("?");
    expect(dialog()).toBeNull();

    await press("?");
    const close = Array.from(dialog()!.querySelectorAll("button")).find((b) => b.textContent?.trim() === "Close")!;
    await act(async () => close.click());
    expect(dialog()).toBeNull();
  });

  it("keeps Tab inside the overlay", async () => {
    await mount();
    await press("?");
    const d = dialog()!;
    for (let i = 0; i < 6; i += 1) {
      await act(async () => {
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
      });
      expect(d.contains(document.activeElement), `tab ${i}`).toBe(true);
    }
  });

  it("does not open while typing in a field", async () => {
    await mount();
    host.querySelector<HTMLElement>("#field")!.focus();
    await press("?");
    expect(dialog()).toBeNull();
  });
});

describe("number keys follow the rail", () => {
  it("goes to each surface by its position", async () => {
    await mount();
    host.querySelector<HTMLElement>("#behind")!.focus();
    for (const k of NAV_KEYS) {
      await press(k.key);
      expect(navigate).toHaveBeenLastCalledWith(k.path);
    }
  });

  it("types the digit instead when a field has focus", async () => {
    await mount();
    host.querySelector<HTMLElement>("#field")!.focus();
    await press("2");
    expect(navigate).not.toHaveBeenCalled();
  });

  it("does not navigate from behind an open dialog", async () => {
    await mount();
    await press("?");
    await press("2");
    expect(navigate).not.toHaveBeenCalled();
  });
});
