"""Literal fake ADB and runner programs for Linux process-contract tests."""

ADB = r'''
import json,os,pathlib,signal,sys,time
p=pathlib.Path(os.environ['FAKE_ANDROID_STATE'])
s=json.loads(p.read_text());a=sys.argv[1:]
def save_state():
 temporary=p.with_name('.'+p.name+'.'+str(os.getpid())+'.tmp')
 with temporary.open('x') as stream:json.dump(s,stream)
 os.replace(temporary,p)
with p.with_suffix('.calls').open('a') as log:log.write(json.dumps(a)+'\n')
if a[:2]!=['-s','fixture-serial']:sys.exit(22)
a=a[2:]
if s.get('blockQuery') and pathlib.Path(os.environ['FAKE_SESSION_ROOT'],'one/guard-ready.json').exists() and not s.get('blockedOnce'):
 s['blockedOnce']=True;save_state();p.with_suffix('.blocked').write_text('ready');time.sleep(.6)
if s.get('slowCleanup') and s['active'] and pathlib.Path(os.environ['FAKE_SESSION_ROOT'],'one/finish.json').exists():time.sleep(2.6)
if s.get('disconnect') and s['active']:sys.exit(21)
if a==['get-state']:print('device')
elif a[:1]==['shell']:
 a=a[1:]
 if a[:2]==['run-as',s['package']]:a=a[2:]
 if a==['id','-u']:print(s['uid']+(1 if s.get('foreignUid') else 0))
 elif a[:2]==['pm','path']:print('package:/data/app/fixture/base.apk')
 elif a[:1]==['sha256sum']:
  if len(a)!=2:sys.exit(27)
  if a[1]=='/data/app/fixture/base.apk':digest='a'*64
  elif a[1]=='app_flutter/flutter_assets/kernel_blob.bin':
   if s.get('kernelMissing'):sys.exit(2)
   digest=('c' if s.get('kernelMismatch') else 'b')*64
  else:sys.exit(28)
  print(digest+'  '+a[1])
 elif a[:1]==['ps']:
  if s['active'] and s.get('loseGuardDuringPostLaunchPs') and not s.get('guardLostBeforeReceipt'):
   directory=pathlib.Path(os.environ['FAKE_SESSION_ROOT'],'one')
   ready=json.loads((directory/'guard-ready.json').read_text())
   runner=json.loads((directory/'lifecycle.json').read_text())['hostIdentities'][-1]
   def identity(pid):
    proc=pathlib.Path('/proc',str(pid));raw=(proc/'stat').read_text();fields=raw[raw.rfind(')')+2:].split()
    return {'pid':pid,'uid':proc.stat().st_uid,'starttime':int(fields[19]),'ppid':int(fields[1]),'state':fields[0]}
   child=identity(ready['pid']);parent=identity(runner['pid'])
   assert child['uid']==ready['uid']==os.getuid() and child['starttime']==ready['starttime']
   assert parent['uid']==runner['uid']==os.getuid() and parent['starttime']==runner['starttime']
   assert child['ppid']==parent['pid'] and child['state'] not in ('Z','X') and parent['state'] not in ('Z','X')
   os.kill(child['pid'],signal.SIGTERM)
   deadline=time.monotonic()+1
   while True:
    try:gone=identity(parent['pid'])['state'] in ('Z','X')
    except FileNotFoundError:gone=True
    if gone and (directory/'resource-run/result.json').exists():break
    assert time.monotonic()<deadline,'Fixture guard did not exit before inventory response'
    time.sleep(.01)
   s['guardLostBeforeReceipt']=True;save_state()
  if s['active'] and s.get('slowFirstPostLaunchPs') and not s.get('postLaunchPsDelayed'):
   s['postLaunchPsDelayed']=True;save_state();time.sleep(3.2)
  if s.get('invalidPs') and s['active']:print('INVALID');sys.exit(0)
  print('PID UID NAME')
  if s['active']:
   for i,pid in enumerate(s['pids']):print(pid,s['uid'],s.get('processNameOverride',s['package']+(':'+str(i) if i else '')))
 elif a[:1]==['cat']:
  stat=pathlib.Path(a[1]).read_text()
  if s.get('invalidStarttime'):
   cut=stat.rfind(')')+2;fields=stat[cut:].split();fields[19]='private-token-canary';stat=stat[:cut]+' '.join(fields)
  if s.get('reuse'):
   cut=stat.rfind(')')+2;fields=stat[cut:].split();fields[19]=str(int(fields[19])+1);stat=stat[:cut]+' '.join(fields)
  print(stat)
 elif a[:2]==['am','start']:
  expected=s['package']+'/com.pietrocode.epubtomp3.flutter_app.MainActivity'
  if a not in (['am','start','-W','-n',expected],['am','start','-n',expected]):
   print('Error type 3\nError: Activity class does not exist');sys.exit(0)
  s['active']=True;s['launches']+=1;save_state()
  if s.get('slowAmStart'):time.sleep(3.2)
  if s.get('delayedFirstDraw'):
   s['firstDrawPending']=True;save_state()
   if '-W' in a:
    time.sleep(3.2);s['firstDrawPending']=False;save_state()
  p.with_suffix('.am-returned').write_text('response')
  print('Status: ok')
 elif a[:2]==['am','force-stop']:
  if s.get('failStop'):sys.exit(23)
  if a[2:]!=[s['package']]:sys.exit(24)
  for pid in s['pids']:
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
  s['active']=False;s['stops']+=1;save_state()
 else:sys.exit(25)
else:sys.exit(26)
'''

GUARD = r'''
import json,os,pathlib,signal,subprocess,sys,time
a=sys.argv[1:];directory=pathlib.Path(a[a.index('--log')+1]);directory.mkdir()
seconds=float(a[a.index('--seconds')+1]);command=a[a.index('--')+1:]
mode=os.environ.get('FAKE_GUARD_MODE','normal');stop=[0]
for sig in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(sig,lambda n,f:stop.__setitem__(0,n))
if mode=='deny':sys.exit(75)
if mode=='early':sys.exit(0)
if mode=='orphanBeforeHandshake':
 child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'],start_new_session=True)
 stat=pathlib.Path('/proc',str(child.pid),'stat').read_text();v=stat[stat.rfind(')')+2:].split()
 (directory/'child.json').write_text(json.dumps({'pid':child.pid,'starttime':int(v[19])}))
 sys.exit(0)
if mode=='stale':
 path=directory.parent/'guard-ready.json';path.write_text('{}');os.utime(path,(1,1))
 while not stop[0]:time.sleep(.02)
 sys.exit(143)
if mode=='zombie':
 child=os.fork()
 if child==0:os._exit(0)
 time.sleep(.05)
 stat=pathlib.Path('/proc',str(child),'stat').read_text();v=stat[stat.rfind(')')+2:].split()
 receipt={'ready':True,'pid':child,'ppid':int(v[1]),'pgid':int(v[2]),'starttime':int(v[19]),'uid':os.getuid()}
 (directory.parent/'guard-ready.json').write_text(json.dumps(receipt))
 while not stop[0]:time.sleep(.02)
 os.waitpid(child,0);sys.exit(143)
child=subprocess.Popen(command,start_new_session=True)
(directory/'child.json').write_text(json.dumps({'pid':child.pid}))
deadline=time.monotonic()+seconds;code=125
try:
 while child.poll() is None and not stop[0] and time.monotonic()<deadline:time.sleep(.02)
 if child.poll() is not None:code=child.returncode if child.returncode>=0 else 128-child.returncode
 elif stop[0]:code=128+stop[0]
 else:code=124
finally:
 if child.poll() is None:
  os.killpg(child.pid,signal.SIGTERM)
  try:child.wait(timeout=.2)
  except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
(directory/'result.json').write_text(json.dumps({'status':code}))
sys.exit(code)
'''
