#!/usr/bin/env python3
"""A fake Whisper server for the queue test: slowwhisper.py <port> <mode file>.
The mode file says how to answer a transcription: "503" fails with a server error, "slow <seconds>" waits that long
and returns one segment. Any GET (the reachability check) gets 200."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, mode_file = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {"data": []})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        mode = open(mode_file).read().split()
        if mode[0] == "503":
            self.reply(503, {"detail": "test: model is loading"})
            return
        time.sleep(float(mode[1]))
        self.reply(200, {"text": "The slow server answered.", "duration": 7.0, "language": "en",
                         "segments": [{"start": 0.5, "end": 3.0, "text": "The slow server answered."}]})


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
