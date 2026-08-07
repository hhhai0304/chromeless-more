#!/usr/bin/env python3
"""Throttled static server with Range support, so downloads are slow enough to
watch and resumable enough to test pause/resume."""
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
RATE = int(os.environ.get("RATE", 2_000_000))  # bytes/sec
NORANGE = os.environ.get("NORANGE") == "1"
CHUNK = 32 * 1024


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            path = "/index.html"
        full = os.path.normpath(os.path.join(ROOT, path.lstrip("/")))
        if not full.startswith(ROOT) or not os.path.isfile(full):
            self.send_error(404)
            return

        size = os.path.getsize(full)
        start, end = 0, size - 1
        status = 200

        rng = self.headers.get("Range")
        if rng and not NORANGE:
            m = re.match(r"bytes=(\d+)-(\d*)", rng)
            if m:
                start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
                status = 206

        length = end - start + 1
        ctype = "text/html" if full.endswith(".html") else (
            "text/plain" if full.endswith(".txt") else "application/octet-stream")

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        # WebKit only hands back resumeData when it has a validator to check the
        # partial file against, so a fixture without these cannot test resume.
        mtime = os.path.getmtime(full)
        self.send_header("ETag", '"%x-%x"' % (int(mtime), size))
        self.send_header("Last-Modified",
                         time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(mtime)))
        if not NORANGE:
            self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        if "attach" in self.path:
            self.send_header("Content-Disposition",
                             'attachment; filename="attached-name.txt"')
        self.end_headers()

        with open(full, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                data = f.read(min(CHUNK, left))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(data)
                if RATE > 0:
                    time.sleep(len(data) / RATE)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8999
    print(f"serving {ROOT} on :{port} rate={RATE}B/s norange={NORANGE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
