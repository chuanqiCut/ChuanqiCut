import http.server, socketserver, os
os.chdir('/tmp/probe_upload')
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        name = os.path.basename(self.path)
        with open(name if name else 'unnamed', 'wb') as f:
            f.write(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        self.send_response(200); self.end_headers()
    def do_POST(self):
        self.do_PUT()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", 8931), H) as httpd:
    print("upload server on :8931")
    httpd.serve_forever()
