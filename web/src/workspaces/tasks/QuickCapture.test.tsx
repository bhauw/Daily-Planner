/*
 * The "C" printed under the capture field is live: pressed anywhere in Tasks it puts focus in
 * the field, and pressed inside a field it is just the letter c.
 */

// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";

(globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QuickCapture } from "./QuickCapture";

let host: HTMLElement;
let root: Root;

async function mount() {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root.render(
      createElement(
        "div",
        null,
        createElement("button", { id: "elsewhere" }, "Elsewhere"),
        createElement("textarea", { id: "notes" }),
        createElement(QuickCapture, {
          captures: [],
          lists: [],
          onCapture: () => {},
          onPickList: () => {},
          onResolve: () => {},
          onDismiss: () => {},
        }),
      ),
    );
  });
}

afterEach(() => {
  act(() => root.unmount());
  host.remove();
});

async function press(key: string) {
  const target = (document.activeElement as HTMLElement | null) ?? document.body;
  await act(async () => {
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

const field = () => host.querySelector<HTMLInputElement>(".capture__input")!;

describe("quick capture's key", () => {
  it("C focuses the capture field from elsewhere on the page", async () => {
    await mount();
    host.querySelector<HTMLElement>("#elsewhere")!.focus();
    await press("c");
    expect(document.activeElement).toBe(field());
  });

  it("does not steal focus while typing in another field", async () => {
    await mount();
    const notes = host.querySelector<HTMLElement>("#notes")!;
    notes.focus();
    await press("c");
    expect(document.activeElement).toBe(notes);
  });

  it("prints the key it listens for", async () => {
    await mount();
    expect(host.querySelector(".capture__hint kbd")?.textContent).toBe("C");
  });
});
