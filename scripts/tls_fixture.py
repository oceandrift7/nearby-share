"""Ephemeral loopback TLS fixture for iOS simulator tests; no committed keys."""
from pathlib import Path
import subprocess, ssl, http.server, sys, os, json, hashlib, re, urllib.parse, time, socket, urllib.request
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
elif sys.argv[1] == 'check':
    # An idle/preconnected TCP peer must not block another client's TLS handshake.
    context = ssl.create_default_context(cafile=str(cert)); context.check_hostname = False
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    with socket.create_connection(('127.0.0.1',19443),timeout=5):
        with opener.open('https://127.0.0.1:19443/manifest',timeout=5) as response:
            assert response.read() == b'{"ok":true}'
    print('PASS: idle TCP client does not block the TLS fixture')
else:
    resume_size = 3*1024*1024+17
    resume_bytes = (bytes(range(251)) * ((resume_size+250)//251))[:resume_size]
    resume_hash = hashlib.sha256(resume_bytes).hexdigest()
    dropped = set()
    benchmark_size = int(os.environ.get('BENCHMARK_MIB','64'))*1024*1024
    benchmark_hasher = hashlib.sha256()
    for _ in range(benchmark_size//262144): benchmark_hasher.update(b'Z'*262144)
    benchmark_hash = benchmark_hasher.hexdigest()
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == '/benchmark-range':
                match = re.fullmatch(r'bytes=(\d+)-(\d+)',self.headers.get('Range',''))
                if not match or self.headers.get('If-Match') != '"'+benchmark_hash+'"':
                    self.send_error(412); return
                start,end = map(int,match.groups())
                if start > end or end >= benchmark_size: self.send_error(416); return
                self.send_response(206); self.send_header('Content-Length',str(end-start+1))
                self.send_header('Content-Range',f'bytes {start}-{end}/{benchmark_size}')
                self.send_header('ETag','"'+benchmark_hash+'"'); self.end_headers()
                self.wfile.write(b'Z'*(end-start+1)); return
            if parsed.path == '/resume-test':
                params = urllib.parse.parse_qs(parsed.query)
                fault = params.get('fault',[''])[0]
                key = params.get('run',[''])[0]
                match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range',''))
                if not match or self.headers.get('If-Match') != '"'+resume_hash+'"':
                    self.send_error(412); return
                start,end = map(int,match.groups())
                if start > end or end >= resume_size:
                    self.send_error(416); return
                body = resume_bytes[start:end+1]
                if fault == 'corrupt' and start >= 1024*1024: body = b'X'*len(body)
                self.send_response(200 if fault == 'ignore' else 206)
                self.send_header('Content-Length',str(len(body)))
                self.send_header('Content-Range',f'bytes {start+1 if fault == "wrong-range" else start}-{end}/{resume_size}')
                self.send_header('ETag','"'+('different' if fault == 'wrong-file' else resume_hash)+'"')
                self.end_headers()
                if fault == 'drop' and start == 1024*1024 and key not in dropped:
                    dropped.add(key); self.wfile.write(body[:65536]); self.close_connection = True
                elif fault == 'slow' and start >= 1024*1024:
                    for offset in range(0,len(body),16384):
                        self.wfile.write(body[offset:offset+16384]); self.wfile.flush(); time.sleep(0.01)
                else: self.wfile.write(body)
                return
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
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
    class TLSServer(http.server.ThreadingHTTPServer):
        def process_request_thread(self, request, address):
            try:
                request.settimeout(15)
                secure = context.wrap_socket(request,server_side=True)
                super().process_request_thread(secure,address)
            except OSError:
                request.close()
    server=TLSServer(('127.0.0.1',19443),Handler)
    server.serve_forever()
