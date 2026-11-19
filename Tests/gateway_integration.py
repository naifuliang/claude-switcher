"""Isolated loopback acceptance: no real credentials, Claude settings or network providers."""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import uuid

seen = []
class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        seen.append((self.server.label, self.path, dict(self.headers)))
        self.send_response(302)
        self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/must-not-follow')
        self.send_header('Content-Length', '0')
        self.end_headers()
    def do_POST(self):
        seen.append((self.server.label, self.path, dict(self.headers)))
        body = self.rfile.read(int(self.headers['Content-Length']))
        assert json.loads(body)['model'] == 'fixture-model'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        for suffix in ['first', 'last']:
            data = f'data: {self.server.label}-{suffix}\n\n'.encode()
            self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
            self.wfile.flush()
            if suffix == 'first':
                time.sleep(0.5)
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

servers=[]
for label in ['A','B']:
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
    server.label=label
    servers.append(server)
    threading.Thread(target=server.serve_forever,daemon=True).start()

with tempfile.TemporaryDirectory(prefix='switcher-gateway-test-') as directory:
    root=Path(directory)
    ids=[str(uuid.uuid4()) for _ in servers]
    profiles=[dict(id=key,name=server.label,kind='gateway',apiKey='provider-'+server.label,
                   baseURL=f'http://127.0.0.1:{server.server_port}',authScheme='x-api-key',models=['fixture-model'])
              for key,server in zip(ids,servers)]
    (root/'profiles.json').write_text(json.dumps(profiles))
    settings=dict(enabled=True,selectedProfileID=ids[0],secret='local-fixture-secret')
    def save():
        temp=root/'next.json'
        temp.write_text(json.dumps(settings))
        temp.replace(root/'gateway.json')
    save()
    binary=Path(__file__).resolve().parents[1]/'.build/release/ClaudeSwitcher'
    process=subprocess.Popen([str(binary),'gateway-serve'],env=dict(os.environ,CLAUDE_SWITCHER_HOME=directory),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if process.poll() is not None: raise AssertionError('Gateway exited before listening')
            try:
                with socket.create_connection(('127.0.0.1',41879),timeout=.1): break
            except OSError: time.sleep(.05)
        else: raise AssertionError('Gateway startup timeout')
        def request(method,path,authorized=True):
            connection=http.client.HTTPConnection('127.0.0.1',41879,timeout=5)
            headers={'Content-Type':'application/json','Cookie':'must-not-forward'}
            if authorized: headers['Authorization']='Bearer local-fixture-secret'
            connection.request(method,path,body=json.dumps({'model':'fixture-model','stream':True}) if method=='POST' else None,headers=headers)
            return connection,connection.getresponse()
        first,response=request('POST','/v1/messages')
        assert response.status==200
        started=time.monotonic()
        assert response.readline()==b'data: A-first\n'
        assert time.monotonic()-started<.4, 'Response was buffered instead of streamed'
        settings['selectedProfileID']=ids[1]
        save()
        assert b'A-last' in response.read(), 'In-flight request changed accounts'
        first.close()
        second,response=request('POST','/v1/messages')
        assert response.status==200 and b'B-first' in response.read(), 'New request did not use the selected account'
        second.close()
        unauthorized,response=request('GET','/v1/models',False)
        assert response.status==401
        response.read(); unauthorized.close()
        redirect,response=request('GET','/v1/models')
        assert response.status==302
        response.read(); redirect.close()
        assert not any(path=='/must-not-follow' for _,path,_ in seen), 'Followed credential-bearing redirect'
        for label,path,headers in seen:
            lowered={key.lower():value for key,value in headers.items()}
            assert lowered.get('x-api-key')=='provider-'+label
            assert 'authorization' not in lowered and 'cookie' not in lowered
        assert process.poll() is None
        print('PASS: live SSE streaming; in-flight route pinned; next request hot-switched; local authentication; credential/header isolation; redirects refused; process not restarted.')
    finally:
        process.terminate()
        process.wait(timeout=5)
        for server in servers:server.shutdown()
