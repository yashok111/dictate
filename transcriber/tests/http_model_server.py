"""Small, local-only HTTP fixture for URLSession integration tests."""

import argparse
import http.server
import time
from pathlib import Path

PAYLOAD = b"abc" * 65536


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/missing":
            self.send_error(404)
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/file")
            self.end_headers()
            return
        offset = 0
        if self.headers.get("Range", "").startswith("bytes="):
            offset = int(self.headers["Range"][6:].split("-")[0])
        payload = PAYLOAD[offset:]
        self.send_response(206 if offset else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"model-fixture-v1"')
        if offset:
            self.send_header(
                "Content-Range", f"bytes {offset}-{len(PAYLOAD) - 1}/{len(PAYLOAD)}"
            )
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.path == "/truncated":
            self.wfile.write(payload[:100])
            self.close_connection = True
            return
        try:
            for pos in range(0, len(payload), 4096):
                self.wfile.write(payload[pos : pos + 4096])
                self.wfile.flush()
                if self.path == "/slow":
                    time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("address_file", type=Path)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    args.address_file.write_text(f"http://127.0.0.1:{server.server_port}")
    server.serve_forever()
