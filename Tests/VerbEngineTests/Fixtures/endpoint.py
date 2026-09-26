#!/usr/bin/python3
# A local OpenAI-compatible server for the engine tests. Chat completions answer with the text
# they were sent; the reasoning route refuses temperature and max_tokens with OpenAI's own
# errors; the download drops its first connection partway. Every request is logged as JSON.
import hashlib,json,socket,sys
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
log=open(sys.argv[1],'a',buffering=1)
weights=bytes((i*7)%251 for i in range(3_000_000))
dropped=[]
refusals={'temperature':"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported.",'max_tokens':"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}

class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def reply(self,status,body):
  data=json.dumps(body).encode()
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  log.write(json.dumps({'path':self.path,'keys':sorted(body)})+'\n')
  if self.path.startswith('/reasoning/'):
   for key,message in refusals.items():
    if key in body:return self.reply(400,{'error':{'message':message,'type':'invalid_request_error','param':key,'code':'unsupported_parameter'}})
   assert body['max_completion_tokens']>0
  if self.path.startswith('/invalid/'):return self.reply(400,{'error':{'message':'Invalid model name.','type':'invalid_request_error'}})
  self.reply(200,{'choices':[{'message':{'content':json.loads(body['messages'][1]['content'])['text']},'finish_reason':'stop'}]})
 def do_GET(self):
  log.write(json.dumps({'path':self.path,'range':self.headers.get('Range')})+'\n')
  start=int(self.headers['Range'].split('=')[1].split('-')[0]) if self.headers.get('Range') else 0
  self.send_response(206 if start else 200)
  if start:self.send_header('Content-Range','bytes %d-%d/%d'%(start,len(weights)-1,len(weights)))
  self.send_header('Content-Length',str(len(weights)-start));self.send_header('ETag','"weights-1"');self.send_header('Accept-Ranges','bytes');self.end_headers()
  if not start and not dropped:
   dropped.append(True)
   self.wfile.write(weights[:1_200_000]);self.wfile.flush()
   self.connection.shutdown(socket.SHUT_RDWR);self.close_connection=True;return
  self.wfile.write(weights[start:])

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],hashlib.sha256(weights).hexdigest(),flush=True)
server.serve_forever()
