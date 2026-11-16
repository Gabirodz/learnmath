"""Static file server for the built Flutter web app (build/web), stdlib only.

Usage: python3 tool/serve_web.py [--dir build/web] [--port 8790] [--bind 127.0.0.1]

The COOP/COEP headers make the page cross-origin isolated, so multi-threaded
WebAssembly (SharedArrayBuffer) is available in the browser.
"""

import argparse
import functools
import http.server
import os
import posixpath
import sys
import urllib.parse

ISOLATION_HEADERS = {
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "credentialless",
    "Cross-Origin-Resource-Policy": "same-origin",
}
NO_CACHE_FILES = {
    "index.html",
    "flutter_bootstrap.js",
    "flutter_service_worker.js",
    "version.json",
    "manifest.json",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".mjs": "text/javascript",
        ".js": "text/javascript",
        ".json": "application/json",
    }

    def __init__(self, *args, verbose=False, **kwargs):
        self.verbose = verbose
        super().__init__(*args, **kwargs)

    def _spa_fallback(self) -> None:
        """Serve index.html for missing extensionless paths (client-side routes)."""
        raw_path = urllib.parse.urlsplit(self.path).path
        last = posixpath.basename(urllib.parse.unquote(raw_path))
        if not os.path.exists(self.translate_path(raw_path)) and not posixpath.splitext(last)[1]:
            self.path = "/index.html"

    def do_GET(self) -> None:
        self._spa_fallback()
        super().do_GET()

    def do_HEAD(self) -> None:
        self._spa_fallback()
        super().do_HEAD()

    def end_headers(self) -> None:
        for name, value in ISOLATION_HEADERS.items():
            self.send_header(name, value)
        path = urllib.parse.urlsplit(self.path).path
        if path == "/" or posixpath.basename(path) in NO_CACHE_FILES:
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, format, *args) -> None:
        if self.verbose:
            super().log_message(format, *args)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Serve a built Flutter web app with COOP/COEP headers.")
    parser.add_argument("--dir", default="build/web", help="directory to serve (default: build/web)")
    parser.add_argument("--port", type=int, default=8790, help="port to listen on (default: 8790)")
    parser.add_argument("--bind", default="127.0.0.1", help="address to bind (default: 127.0.0.1)")
    parser.add_argument("--verbose", action="store_true", help="log each request")
    args = parser.parse_args(argv)

    directory = os.path.abspath(args.dir)
    if not os.path.isdir(directory):
        print(f"error: directory does not exist: {directory}", file=sys.stderr)
        return 2

    handler = functools.partial(Handler, directory=directory, verbose=args.verbose)
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"Serving {directory} at http://{args.bind}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
