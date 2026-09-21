import Foundation

/// Serves the built React bundle (`web/dist`, copied into the app bundle) at `/`. If the bundle
/// is absent — for example before task 03 lands, or in a dev checkout — it serves an explicit
/// placeholder page rather than crashing or failing silently.
struct StaticWebAssets {
    /// Root directory of built web assets, or nil if none was supplied.
    let root: URL?

    private static let indexNames = ["index.html"]

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "map": "application/json; charset=utf-8",
    ]

    func response(for path: String) -> HTTPResponse {
        guard let root, let fileURL = resolve(path, under: root) else {
            return placeholder()
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            // A single-page app: unknown non-file paths fall back to index.html.
            if let index = try? Data(contentsOf: root.appendingPathComponent("index.html")) {
                return HTTPResponse(
                    status: 200, reason: "OK",
                    headers: [("Content-Type", "text/html; charset=utf-8")],
                    body: index
                )
            }
            return placeholder()
        }
        let ext = fileURL.pathExtension.lowercased()
        let type = Self.contentTypes[ext] ?? "application/octet-stream"
        return HTTPResponse(status: 200, reason: "OK", headers: [("Content-Type", type)], body: data)
    }

    /// Resolves a request path to a file inside `root`, refusing any path that would escape it.
    private func resolve(_ path: String, under root: URL) -> URL? {
        var relative = path
        if relative == "/" {
            relative = "/index.html"
        }
        // Reject traversal outright — no `..` segment ever reaches the filesystem.
        let segments = relative.split(separator: "/").map(String.init)
        guard !segments.contains("..") else { return nil }
        var url = root
        for segment in segments {
            url.appendPathComponent(segment)
        }
        return url
    }

    private func placeholder() -> HTTPResponse {
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Daily Planner</title>
          <style>
            :root { color-scheme: dark; }
            body {
              margin: 0; min-height: 100vh;
              display: grid; place-items: center;
              background: #1E1E1E; color: #FFFFFF;
              font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main { max-width: 34rem; padding: 2rem; text-align: center; }
            h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
            p { color: #98989D; margin: .25rem 0; }
            code { font-family: "SF Mono", ui-monospace, monospace; color: #98989D; }
            .rail {
              margin-top: 1.5rem; display: inline-block;
              padding: .35rem .75rem; border-radius: 6px;
              background: #2C2C2C; color: #98989D; font-size: 13px;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Daily Planner engine is running</h1>
            <p>The web UI bundle has not been built yet.</p>
            <p>Run <code>npm run build</code> in <code>web/</code>, or launch with
               <code>?dev=1</code> to use the Vite dev server.</p>
            <p class="rail">Read-only · no external writes</p>
          </main>
        </body>
        </html>
        """
        return HTTPResponse(
            status: 200, reason: "OK",
            headers: [("Content-Type", "text/html; charset=utf-8")],
            body: Data(html.utf8)
        )
    }
}
