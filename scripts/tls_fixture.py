"""Ephemeral loopback TLS fixture for iOS simulator tests; no committed keys."""
from pathlib import Path
import subprocess, ssl, http.server, sys, os, json
root = Path(__file__).resolve().parents[1]
folder = root / 'ios/Tests/Fixtures'
folder.mkdir(exist_ok=True)
storage = root / 'ios/build-fixture'
storage.mkdir(exist_ok=True)
cert, key = storage/'localhost.pem', storage/'localhost.key'
if sys.argv[1] == 'prepare':
    mib = int(os.environ.get('BENCHMARK_MIB', '64'))
    assert mib in (8,64,256)
    (folder/'benchmark.json').write_text(json.dumps({'mib':mib}))
    subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout',str(key),'-out',str(cert),'-days','2','-subj','/CN=Nearby test'],check=True)
    subprocess.run(['openssl','x509','-in',str(cert),'-outform','DER','-out',str(folder/'localhost.der')],check=True)
else:
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ('/bad-hash', '/truncated'):
                self.send_response(200)
                self.send_header('Content-Length', '8192' if self.path == '/truncated' else '4096')
                self.end_headers(); self.wfile.write(b'Z'*4096)
                self.close_connection = True
                return
            if self.path.startswith('/benchmark'):
                mib = int(os.environ.get('BENCHMARK_MIB', '64'))
                self.send_response(200); self.send_header('Content-Length', str(mib*1024*1024)); self.end_headers()
                for _ in range(mib*4): self.wfile.write(b'Z'*262144)
                return
            data=b'{"ok":true}'
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',19443),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
    server.socket=context.wrap_socket(server.socket,server_side=True)
    server.serve_forever()
