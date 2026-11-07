#!/usr/bin/env python3
"""Loopback-only HTTP fixture server with byte ranges. Used by URLRangeTests."""
import functools
import http.server
import pathlib
import re
import sys
import ssl


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_head(self):
        if hasattr(self, 'remaining'):
            del self.remaining
        path = pathlib.Path(self.translate_path(self.path))
        if not path.is_file():
            return super().send_head()
        source = path.open('rb')
        length = path.stat().st_size
        start, end = 0, length - 1
        header = self.headers.get('Range')
        if header:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', header)
            if not match or int(match[1]) >= length:
                source.close()
                self.send_error(416)
                return None
            start = int(match[1])
            if match[2]:
                end = min(end, int(match[2]))
            if end < start:
                source.close()
                self.send_error(416)
                return None
        self.send_response(206 if header else 200)
        self.send_header('Content-type', self.guess_type(str(path)))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if header:
            self.send_header('Content-Range', f'bytes {start}-{end}/{length}')
        self.end_headers()
        source.seek(start)
        self.remaining = end - start + 1
        return source

    def copyfile(self, source, output):
        if not hasattr(self, 'remaining'):
            return super().copyfile(source, output)
        remaining = self.remaining
        try:
            while remaining:
                block = source.read(min(65536, remaining))
                if not block:
                    break
                output.write(block)
                remaining -= len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(
    ('127.0.0.1', 0), functools.partial(Handler, directory=sys.argv[1]))
if len(sys.argv) == 4:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
