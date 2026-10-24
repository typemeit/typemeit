# Serves the repo so a render.html (Scripts/og, Scripts/puff) can pull
# web/puff.glsl.js, and accepts the rendered PNG back as a POST into the
# directory given as the first argument. A browser is the only thing here that
# can run the shader; this is how its pixels reach disk.
#
#   python3 Scripts/render-serve.py /tmp/out       # Scripts/generate-og.sh runs this
#   python3 Scripts/render-serve.py Scripts/puff   # the disk image background's puffs, then:
#   open http://127.0.0.1:8792/Scripts/puff/render.html?name=p1&size=520&exp=0.55&trail=0.5&flow=0.35&time=140
import http.server, os, sys, urllib.parse
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.abspath(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = os.path.basename(q['name'][0])
        data = self.rfile.read(int(self.headers['Content-Length']))
        open(os.path.join(OUT, name), 'wb').write(data)
        self.send_response(200); self.end_headers(); self.wfile.write(f"{name} {len(data)}".encode())
    def log_message(self, *a): pass
os.chdir(ROOT)
http.server.HTTPServer(('127.0.0.1', 8792), H).serve_forever()
