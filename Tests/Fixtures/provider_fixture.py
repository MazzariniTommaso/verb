import json
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        assert self.headers.get('Authorization') == 'Bearer verb-test-key'
        if self.path == '/transcribe':
            assert b'name="model"\r\n\r\ntest-stt' in body
            assert b'name="prompt"\r\n\r\nMazzarini' in body
            assert b'name="file"' in body
            print(json.dumps({'upload_bytes': len(body), 'compressed': b'filename="dictation.m4a"' in body}), flush=True)
            result = {'text': 'Ciao test', 'language': 'it'}
        elif self.path == '/chat':
            data = json.loads(body)
            assert data['model'] == 'test-writer'
            assert data['messages'][0]['role'] == 'system'
            assert json.loads(data['messages'][1]['content'])['text'] == 'Ciao test'
            result = {'choices': [{'message': {'content': 'Ciao test.'}, 'finish_reason': 'stop'}]}
        elif self.path.startswith('/status/'):
            self.send_response(int(self.path.rsplit('/', 1)[1]))
            self.send_header('Location', 'http://127.0.0.1:11436/redirect-target')
            self.end_headers()
            return
        else:
            raise AssertionError('Redirect must never be followed')
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

HTTPServer(('127.0.0.1', 11436), Handler).serve_forever()
