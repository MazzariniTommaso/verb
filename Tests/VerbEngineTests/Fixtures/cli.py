#!/usr/bin/python3
# Protocol fixtures, using shapes from the official SDKs. No network or real auth.
import json,sys,time,os
from pathlib import Path
provider=Path(sys.argv[0]).stem
args=sys.argv[1:]
# Dictated text and dictionary words travel on stdin or in private files, never in argv.
assert not any(w in a for a in args for w in ('gatto','divano','Mazzarini'))
if provider=='gemini' and '--experimental-acp' in args:
 settings=json.load(open(os.environ['GEMINI_CLI_SYSTEM_SETTINGS_PATH']))
 assert settings['privacy']['usageStatisticsEnabled'] is False and settings['telemetry']['enabled'] is False
if 'hang' in args: time.sleep(15); sys.exit(0)
if 'failed' in args: print('not signed in',file=sys.stderr);sys.exit(2)
if 'overflow' in args: print('x'*4100000);sys.exit(0)
framed='--stdio' in args

def emit(x):
 data=json.dumps(x,ensure_ascii=False).encode()
 if framed:
  # Split headers and Unicode payloads across reads.
  packet=b'Content-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data
  for i in range(0,len(packet),7):
   sys.stdout.buffer.write(packet[i:i+7]);sys.stdout.buffer.flush()
 else: print(data.decode(),flush=True)

def read():
 if not framed:
  line=sys.stdin.buffer.readline()
  return json.loads(line) if line else None
 line=sys.stdin.buffer.readline()
 if not line:return None
 n=int(line.split(b':')[1]);assert sys.stdin.buffer.readline()==b'\r\n'
 return json.loads(sys.stdin.buffer.read(n))

def reply(event,result):emit({'jsonrpc':'2.0','id':event['id'],'result':result})
model={'id':'live-model','name':'Live model','description':'Current fixture model'}
if provider=='claude' and 'auth' in args:
 emit({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty','subscriptionType':'pro'});sys.exit(0)
if provider=='cursor' and args==['status']:print('Logged in as fixture');sys.exit(0)
if provider=='cursor' and '--list-models' in args:print('live-model - Live model\n');sys.exit(0)
if ('--print' in args or ('-p' in args and '--input-format' not in args) or 'exec' in args):
 text=sys.stdin.read();assert 'gatto' in text or 'cat' in text
 if provider=='claude':
  assert '--safe-mode' in args and args[args.index('--tools')+1]=='' and '--system-prompt' not in args
  prompt=args[args.index('--system-prompt-file')+1]
  assert os.stat(prompt).st_mode&0o777==0o600 and 'Mazzarini' in open(prompt,encoding='utf-8').read()
 if provider=='codex':
  assert '--ignore-user-config' in args and '--ephemeral' in args and 'features.shell_tool=false' in args
  emit({'type':'item.completed','item':{'type':'agent_message','text':'{"text":"Il gatto è sulla sedia."}'}})
 else:emit({'type':'result','subtype':'success','is_error':False,'result':'Il gatto è sulla sedia.'})
 sys.exit(0)
while True:
 e=read()
 if e is None:break
 m=e.get('method')
 if e.get('type')=='control_request':
  emit({'type':'control_response','response':{'subtype':'success','request_id':e['request_id'],'response':{'models':[{'value':'live-model','displayName':'Alias','description':'Live model · Fast','resolvedModel':'resolved-live'}]}}})
 elif m=='initialize':reply(e,{'protocolVersion':1})
 elif m=='connect':reply(e,{'protocolVersion':3})
 elif m=='account/read':reply(e,{'account':{'type':'chatgpt','planType':'plus'}})
 elif m=='model/list':
  if e['params'].get('cursor'):reply(e,{'data':[{'model':'second-live','displayName':'Second model'}],'nextCursor':None})
  else:reply(e,{'data':[{'model':'live-model','displayName':'Live model'}],'nextCursor':'page-two'})
 elif m=='auth.getStatus':reply(e,{'isAuthenticated':True})
 elif m=='models.list':reply(e,{'models':[model]})
 elif m=='session/new':reply(e,{'sessionId':'s1','models':{'availableModels':[{'modelId':'live-model','name':'Live model'}],'currentModelId':'live-model'}})
 elif m=='session/set_model':reply(e,{})
 elif m=='session/prompt':
  emit({'method':'session/update','params':{'sessionId':'s1','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Il gatto è sulla sedia.'}}}})
  reply(e,{'stopReason':'end_turn'})
 elif m=='session.create':
  assert e['params']['availableTools']==[] and e['params']['enableFileHooks']==False
  reply(e,{'sessionId':'s1'})
 elif m=='session.options.update':
  assert e['params']['skipCustomInstructions'] and e['params']['installedPlugins']==[]
  reply(e,{})
 elif m=='session.send':
  reply(e,{'messageId':'m1'})
  for kind,data in [('assistant.message',{'content':'Il gatto è sulla sedia.'}),('session.idle',{})]:
   emit({'method':'session.event','params':{'sessionId':'s1','event':{'type':kind,'data':data}}})
