#!/usr/bin/env python3
"""A stand-in for the Acme API from the Dash plugin tutorials, so the Acme plugins show real data.

    python3 examples/MockAcme/server.py            # http://localhost:8787

Then set Acme's Server to http://localhost:8787 in Dash (Settings > Acme) and paste any token.
The token "wrong" is refused, to see the error state. Tickets come from tickets.json next to this
file, read on every request: edit it while Dash runs (add an urgent ticket, close one) and the
next refresh shows the change.

Standard library only. Listens on 127.0.0.1, never on the network.
"""
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TICKETS = pathlib.Path(__file__).with_name("tickets.json")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787


class Acme(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth == "Bearer ":
            return self.answer(401, {"error": "missing token"})
        if auth == "Bearer wrong":
            return self.answer(401, {"error": "bad token"})
        if url.path == "/me":
            return self.answer(200, {"name": "Ada"})
        if url.path == "/tickets":
            try:
                tickets = json.loads(TICKETS.read_text())
            except (OSError, ValueError) as error:
                return self.answer(500, {"error": f"tickets.json: {error}"})
            status = parse_qs(url.query).get("status", [None])[0]
            return self.answer(200, [t for t in tickets if status is None or t.get("status") == status])
        return self.answer(404, {"error": f"no route {url.path}"})

    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        # One line per request, so you can watch what Dash asks for. Never the token itself.
        auth = "with a token" if self.headers.get("Authorization", "").startswith("Bearer ") else "without a token"
        sys.stderr.write(f"{self.command} {self.path} {auth} -> {args[1] if len(args) > 1 else '?'}\n")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Acme)
    print(f"Mock Acme on http://localhost:{PORT} (tickets from {TICKETS}). Ctrl-C stops it.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
