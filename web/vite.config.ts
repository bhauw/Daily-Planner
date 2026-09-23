import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";

// The bundle's own version, for Settings › About. Read from package.json at build time so the
// number shown is the one that was built, not one a component remembers.
const { version } = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as {
  version: string;
};

// The Swift engine serves this build over 127.0.0.1 on a random high port and
// injects the per-launch bearer token before the bundle runs. Relative asset
// paths (base: "./") keep the bundle portable across that random port and across
// detached WKWebView windows that load a sub-route directly.
export default defineConfig({
  plugins: [react()],
  base: "./",
  define: {
    __APP_VERSION__: JSON.stringify(version),
  },
  build: {
    outDir: "dist",
    sourcemap: false,
    target: "es2022",
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: false,
    // In `npm run dev` the engine may not be running; proxy /api to it when it is.
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8787",
        changeOrigin: false,
      },
    },
  },
});
