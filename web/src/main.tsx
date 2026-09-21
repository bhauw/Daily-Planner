import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./app";

// Token layer first, then base element styles. Component CSS is imported by each
// component so the cascade order stays: tokens -> base -> components.
import "./tokens.css";
import "./base.css";

// DEV ONLY: install the synthetic mock engine before anything renders, so
// `npm run dev` shows the full Option A shell with data and no Swift host.
// The dynamic import is guarded by import.meta.env.DEV, so the mock module is
// tree-shaken out of the production bundle the signed app ships.
async function bootstrap() {
  if (import.meta.env.DEV) {
    const { installMockEngine } = await import("./dev/mock");
    installMockEngine();
  }

  const root = document.getElementById("root");
  if (!root) throw new Error("Root element not found");

  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

void bootstrap();
