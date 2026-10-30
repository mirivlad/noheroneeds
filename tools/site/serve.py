#!/usr/bin/env python3
"""Serve a built preview under the real GitHub Pages path."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from build import ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=18764)
parser.add_argument("--directory", type=Path, default=ROOT/"build/site")
args = parser.parse_args()


class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        from urllib.parse import urlsplit
        if not urlsplit(path).path.startswith("/noheroneeds/"):
            return str(args.directory/"__not_found__")
        return super().translate_path(path[len('/noheroneeds'):])


server = ThreadingHTTPServer(("127.0.0.1", args.port), partial(Handler, directory=str(args.directory)))
print(f"Preview: http://127.0.0.1:{args.port}/noheroneeds/", flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally: server.server_close()
