#!/usr/bin/env python3
"""Local host for tools/audio_overlay_web_proof.sh: the web export at /, and /content/* from a disk cache filled on demand from the real content origin."""
import http.server, os, sys, urllib.request, socketserver
root, cache, upstream, port = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/"), int(sys.argv[4])
MIME = {".wasm": "application/wasm", ".js": "text/javascript", ".json": "application/json", ".ogg": "audio/ogg"}
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=root, **k)
    def guess_type(s, p): return MIME.get(os.path.splitext(p)[1], super().guess_type(p))
    def log_message(s, *a): pass
    def do_GET(s):
        if not s.path.startswith("/content/"): return super().do_GET()
        rel = s.path.split("?")[0][len("/content/"):]
        f = os.path.join(cache, rel)
        if not os.path.exists(f):
            os.makedirs(os.path.dirname(f), exist_ok=True)
            try:
                with urllib.request.urlopen(urllib.request.Request(upstream + "/" + rel, headers={"User-Agent": "tmc-proof"}), timeout=30) as r, open(f + ".part", "wb") as o:
                    o.write(r.read())
                os.rename(f + ".part", f)
            except Exception as e:
                s.send_error(404, str(e)); return
        data = open(f, "rb").read()
        s.send_response(200); s.send_header("Content-Length", str(len(data))); s.send_header("Content-Type", MIME.get(os.path.splitext(f)[1], "application/octet-stream")); s.end_headers(); s.wfile.write(data)
class T(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
T(("127.0.0.1", port), H).serve_forever()
