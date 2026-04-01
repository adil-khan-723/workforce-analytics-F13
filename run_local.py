#!/usr/bin/env python3
"""
OrgIQ Workforce Analytics — Local Demo Runner
Starts a local server and opens the dashboard in your browser.
NO AWS ACCOUNT NEEDED — runs entirely on your machine.

Usage:
    python3 run_local.py
    python3 run_local.py --port 8080
"""

import argparse
import http.server
import json
import os
import sys
import threading
import time
import webbrowser
from pathlib import Path

# ── ANSI colours ──────────────────────────────────────────────────
CYAN  = '\033[0;36m'
GREEN = '\033[0;32m'
BOLD  = '\033[1m'
RESET = '\033[0m'

PROJECT_DIR = Path(__file__).parent

BANNER = f"""{CYAN}
   ___            ___ ___
  / _ \\ _ _ __ _ |_ _/ _ \\
 | (_) | '_/ _` | | | (_) |
  \\___/|_| \\__, ||___\\__\\_\\
           |___/  Workforce Intelligence
{RESET}
{BOLD}  Local Demo Mode — no AWS required{RESET}
"""


def main():
    parser = argparse.ArgumentParser(description="OrgIQ local demo server")
    parser.add_argument("--port", type=int, default=5500, help="Port (default: 5500)")
    parser.add_argument("--no-browser", action="store_true", help="Don't open browser automatically")
    args = parser.parse_args()

    print(BANNER)

    frontend_dir = PROJECT_DIR / "frontend"
    if not (frontend_dir / "index.html").exists():
        print(f"  ✗  frontend/index.html not found.")
        print(f"     Make sure you're running this from the workforce-analytics/ directory.")
        sys.exit(1)

    # Ensure DEMO_MODE is true in the HTML
    html_path = frontend_dir / "index.html"
    html = html_path.read_text()
    if "DEMO_MODE: false" in html:
        print(f"  ⚠  Detected DEMO_MODE: false — switching to true for local demo…")
        html = html.replace("DEMO_MODE: false", "DEMO_MODE: true")
        html_path.write_text(html)
        print(f"  ✓  DEMO_MODE set to true")

    # Custom handler: silences 404 noise, adds CORS headers
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(frontend_dir), **kw)

        def log_message(self, fmt, *args):
            pass  # suppress default logging

        def end_headers(self):
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            super().end_headers()

        def do_GET(self):
            # Serve index.html for any unknown path (SPA fallback)
            if self.path == "/" or not (frontend_dir / self.path.lstrip("/")).exists():
                self.path = "/index.html"
            super().do_GET()

    url = f"http://localhost:{args.port}"

    print(f"  Starting server on port {args.port}…")
    server = http.server.HTTPServer(("localhost", args.port), QuietHandler)

    def run_server():
        server.serve_forever()

    t = threading.Thread(target=run_server, daemon=True)
    t.start()
    time.sleep(0.4)

    print(f"\n{GREEN}{BOLD}  ✓  OrgIQ is running!{RESET}")
    print(f"\n  {BOLD}Dashboard URL:{RESET}  {CYAN}{url}{RESET}")
    print(f"\n  {BOLD}Demo login:{RESET}")
    print(f"    Email:    hr.admin@demo.com")
    print(f"    Password: Demo@1234  (any non-empty credentials work in demo mode)")
    print(f"\n  {BOLD}Features available:{RESET}")
    print(f"    ● Overview with 5 KPI cards + 4 charts")
    print(f"    ● Headcount trend (hires vs departures, stacked, donut)")
    print(f"    ● Leave utilisation (grouped bar + dept cards)")
    print(f"    ● Recruitment funnel (bars + conversion rates)")
    print(f"    ● Attrition risk table (sortable, top-10)")
    print(f"    ● Interactive D3 org chart (pan, zoom, tooltips)")
    print(f"    ● System health panel (simulated CloudWatch metrics)")
    print(f"\n  Press {BOLD}Ctrl+C{RESET} to stop the server.\n")

    if not args.no_browser:
        time.sleep(0.5)
        webbrowser.open(url)
        print(f"  Browser opened. If it didn't open, visit: {url}\n")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"\n\n  Shutting down…")
        server.shutdown()
        print(f"  Server stopped. Goodbye!\n")


if __name__ == "__main__":
    main()
