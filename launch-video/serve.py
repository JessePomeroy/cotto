"""Temporary localhost preview with byte ranges for video seeking."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent

class PreviewHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def send_head(self):
        self.remaining = None
        if self.path == "/":
            self.path = "/preview.html"
        path = Path(self.translate_path(self.path))
        requested = self.headers.get("Range")
        if not requested or not path.is_file():
            return super().send_head()
        size = path.stat().st_size
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested)
        if not match or not any(match.groups()):
            self.send_error(416, "Invalid byte range")
            return None
        first, last = match.groups()
        start = int(first) if first else max(0, size - int(last))
        end = min(int(last), size - 1) if first and last else size - 1
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(str(path)))
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        source = path.open("rb")
        source.seek(start)
        self.remaining = end - start + 1
        return source

    def copyfile(self, source, destination):
        try:
            if self.remaining is None:
                return super().copyfile(source, destination)
            while self.remaining > 0:
                chunk = source.read(min(65536, self.remaining))
                if not chunk:
                    break
                destination.write(chunk)
                self.remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == "__main__":
    print("Sotto launch preview: http://localhost:4327", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 4327), PreviewHandler).serve_forever()
