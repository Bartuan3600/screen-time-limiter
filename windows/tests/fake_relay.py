"""Minimaler Attrappen-Server mit den Semantiken von ntfy.sh (Befehle) und textdb.dev (Status) - nur fuer Tests.
ntfy:   POST /<topic>  (Header Tags)          -> speichert Nachricht  {id,time,event,topic,message,tags}
        GET  /<topic>/json?poll=1&since=<id|10m|all>  -> NDJSON; unbekannte (gueltig geformte) ID -> alle Nachrichten (wie ntfy.sh),
                                                       ungueltiges Format -> 400
textdb: POST /api/data/<key> (text/plain)      -> ueberschreibt;  GET -> Wert (404 wenn leer)
"""
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class FakeRelay:
    def __init__(self):
        self.messages = {}      # topic -> [dict]
        self.db = {}            # key -> str
        self.counter = 0
        self.lock = threading.Lock()
        self.fail_status = 0    # wenn > 0: alle Antworten mit diesem Code (Ausfall simulieren)
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n).decode("utf-8")
                path = urlparse(self.path).path
                if outer.fail_status:
                    return self._send(outer.fail_status)
                with outer.lock:
                    if path.startswith("/api/data/"):
                        outer.db[path[len("/api/data/"):]] = body
                        return self._send(200, b"ok")
                    topic = path.strip("/")
                    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", topic):
                        return self._send(400)
                    outer.counter += 1
                    tags = [t.strip() for t in (self.headers.get("Tags") or "").split(",") if t.strip()]
                    m = {"id": "M%011d" % outer.counter, "time": int(time.time()), "event": "message",
                         "topic": topic, "message": body, "tags": tags}
                    outer.messages.setdefault(topic, []).append(m)
                    return self._send(200, json.dumps(m).encode(), "application/json")

            def do_GET(self):
                u = urlparse(self.path)
                if outer.fail_status:
                    return self._send(outer.fail_status)
                with outer.lock:
                    if u.path.startswith("/api/data/"):
                        v = outer.db.get(u.path[len("/api/data/"):])
                        return self._send(200, v.encode()) if v is not None else self._send(404)
                    mm = re.fullmatch(r"/([A-Za-z0-9_-]{1,64})/json", u.path)
                    if not mm:
                        return self._send(404)
                    since = (parse_qs(u.query).get("since") or ["10m"])[0]
                    if not re.fullmatch(r"(all|\d+[smhd]|[A-Za-z0-9]{12})", since):
                        return self._send(400, b'{"code":40008}')
                    msgs = outer.messages.get(mm.group(1), [])
                    ids = [m["id"] for m in msgs]
                    if since in ids:
                        msgs = msgs[ids.index(since) + 1:]
                    out = "".join(json.dumps(m) + "\n" for m in msgs)
                    return self._send(200, out.encode(), "application/x-ndjson")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        self.base = "http://127.0.0.1:%d" % self.port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
