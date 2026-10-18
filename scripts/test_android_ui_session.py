"""Executable Linux contracts: fake ADB only, real independent process groups."""

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

COORDINATOR = Path(__file__).with_name("android_ui_session.py")
BASELINE = "--baseline" in sys.argv
if BASELINE:
    sys.argv.remove("--baseline")

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
  if s['active'] and s.get('slowFirstPostLaunchPs') and not s.get('postLaunchPsDelayed'):
   s['postLaunchPsDelayed']=True;save_state();time.sleep(3.2)
  if s.get('invalidPs') and s['active']:print('INVALID');sys.exit(0)
  print('PID UID NAME')
  if s['active']:
   for i,pid in enumerate(s['pids']):print(pid,s['uid'],s.get('processNameOverride',s['package']+(':'+str(i) if i else '')))
 elif a[:1]==['cat']:
  stat=pathlib.Path(a[1]).read_text()
  if s.get('reuse'):
   cut=stat.rfind(')')+2;fields=stat[cut:].split();fields[19]=str(int(fields[19])+1);stat=stat[:cut]+' '.join(fields)
  print(stat)
 elif a[:2]==['am','start']:
  expected=s['package']+'/com.pietrocode.epubtomp3.flutter_app.MainActivity'
  if a!=['am','start','-W','-n',expected]:
   print('Error type 3\nError: Activity class does not exist');sys.exit(0)
  s['active']=True;s['launches']+=1;save_state()
  if s.get('slowAmStart'):time.sleep(3.2)
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


class SessionContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="android-ui-session-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "device.json"
        self.apps = [subprocess.Popen([sys.executable, "-c", "import time;time.sleep(120)"], start_new_session=True) for _ in range(2)]
        self.addCleanup(self.reap_apps)
        self.state.write_text(json.dumps({"active": False, "uid": 10001,
            "package": "com.pietrocode.epubtomp3.flutter_app.verification",
            "pids": [p.pid for p in self.apps], "launches": 0, "stops": 0}))
        self.adb = self.script("adb", ADB)
        self.guard = self.script("guard.py", GUARD)
        self.wrapper = self.script("wrapper.py", "import os,sys\na=sys.argv[1:];a=a[1:] if a[:1]==['--'] else a\nos.execv(a[0],a)\n")
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"adb": str(self.adb), "serial": "fixture-serial",
            "uid": 10001, "apkSha256": "a"*64, "kernelSha256": "b"*64,
            "runner": self.pin(self.guard), "wrapper": self.pin(self.wrapper),
            "python": sys.executable, "ruby": sys.executable,
            "cwd": str(self.root), "seconds": 6}))
        self.sessions = self.root / "sessions"
        self.env = {**os.environ, "FAKE_ANDROID_STATE": str(self.state),
                    "FAKE_SESSION_ROOT": str(self.sessions)}
        self.process = None

    def pin(self, path):
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def script(self, name, body):
        path = self.root / name
        path.write_text("#!"+sys.executable+"\n"+body)
        path.chmod(0o700)
        return path

    def reap_apps(self):
        for app in self.apps:
            if app.poll() is None:app.terminate()
            app.wait(timeout=3)

    def stop_fixture_host(self, pid, starttime):
        path=Path('/proc',str(pid))
        try:
            stat=(path/'stat').read_text();values=stat[stat.rfind(')')+2:].split()
            self.assertEqual(int(values[19]),starttime,'Fixture PID identity changed; refusing signal')
            self.assertEqual(path.stat().st_uid,os.getuid())
            os.kill(pid,signal.SIGTERM)
            try:os.waitpid(pid,0)
            except ChildProcessError:pass
        except FileNotFoundError:pass

    def mutate(self, **values):
        state = json.loads(self.state.read_text());state.update(values)
        temporary=self.state.with_name('.'+self.state.name+'.'+str(os.getpid())+'.tmp')
        with temporary.open('x') as stream:json.dump(state,stream)
        os.replace(temporary,self.state)

    def start(self, mode="normal"):
        self.env["FAKE_GUARD_MODE"] = mode
        self.process = subprocess.Popen([sys.executable, str(COORDINATOR), "--config", str(self.config),
            "--state-root", str(self.sessions), "--session-id", "one", "--sole-executor"],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(self.stop_coordinator)
        return self.process

    def stop_coordinator(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait()

    def wait(self, predicate):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if predicate():return
            if self.process and self.process.poll() is not None:
                self.fail("Coordinator exited before checkpoint: "+str(self.process.communicate()))
            time.sleep(.02)
        self.fail("Fixture checkpoint timed out")

    def active(self):
        self.wait(lambda: json.loads(self.state.read_text())["active"])
        self.wait(lambda: self.report().get("started") is True)

    def report(self):
        path=self.sessions/'one/lifecycle.json'
        try:return json.loads(path.read_text())
        except (FileNotFoundError,json.JSONDecodeError):return {}

    def finish(self):
        (self.sessions/'one/finish.json').write_text('{}')

    def result(self, expected):
        out,err=self.process.communicate(timeout=18)
        self.stdout=out
        self.assertEqual(self.process.returncode,expected,(out,err))
        return self.report()

    def assert_stopped(self, report):
        self.assertTrue(report['cleanupVerified'])
        self.assertFalse(report['conversionAccepted'])
        self.assertFalse(report['continuousKernelLease'])
        self.assertFalse(json.loads(self.state.read_text())['active'])
        for app in self.apps:app.wait(timeout=3)

    def test_signal_cleanup_reaches_independent_device_processes(self):
        if BASELINE:
            self.mutate(active=True)
            host=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
            host.terminate();host.wait(timeout=3)
            self.assertFalse(self.apps[0].poll() is None,
                'host-only process termination leaves the independent device process alive')
            return
        self.start();self.active();self.process.send_signal(signal.SIGTERM)
        self.assert_stopped(self.result(143))

    def test_normal_exit_cleans_all_package_processes_without_claiming_conversion(self):
        self.start()
        def launch_calls():
            path=self.state.with_suffix('.calls')
            if not path.exists():return []
            return [json.loads(line) for line in path.read_text().splitlines()
                    if json.loads(line)[2:5]==['shell','am','start']]
        self.wait(lambda: bool(launch_calls()))
        self.assertEqual(launch_calls()[-1],['-s','fixture-serial','shell','am','start','-W','-n',
            'com.pietrocode.epubtomp3.flutter_app.verification/com.pietrocode.epubtomp3.flutter_app.MainActivity'])
        self.active();self.finish();self.assert_stopped(self.result(0))

    def test_killed_guard_child_still_cleans_device(self):
        self.start();self.active()
        child=json.loads((self.sessions/'one/resource-run/child.json').read_text())['pid']
        os.kill(child,signal.SIGKILL)
        self.assert_stopped(self.result(137))

    def test_killed_runner_cleans_device_but_blocks_on_orphaned_host_group(self):
        self.start();self.active()
        identities=self.report()['hostIdentities']
        runner=identities[-1]['pid'];waiter=identities[0]['pid']
        try:
            os.kill(runner,signal.SIGKILL)
            report=self.result(125)
            self.assertTrue(report['deviceCleanupVerified'])
            self.assertFalse(report['cleanupVerified'])
            self.assertIn(waiter,report['remainingHostGroupPids'])
            self.assertFalse(json.loads(self.state.read_text())['active'])
            self.process=None;self.start();self.result(75)
        finally:
            self.stop_fixture_host(waiter,identities[0]['starttime'])

    def test_guard_failure_while_active_preserves_nonzero(self):
        self.start();self.active()
        child=json.loads((self.sessions/'one/resource-run/child.json').read_text())['pid']
        os.kill(child,signal.SIGTERM)
        self.assert_stopped(self.result(143))

    def test_deadline_is_interrupted_and_cleans_device(self):
        config=json.loads(self.config.read_text());config['seconds']=2;self.config.write_text(json.dumps(config))
        self.start();self.active();report=self.result(124)
        self.assertTrue(report['interrupted']);self.assert_stopped(report)

    def test_denial_does_not_launch(self):
        self.start('deny');report=self.result(125)
        self.assertFalse(report['hostGroupsAuthenticated'])
        self.assertFalse(report['cleanupVerified'])
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)

    def test_early_exit_does_not_admit(self):
        self.start('early');report=self.result(125)
        self.assertFalse(report['cleanupVerified'])
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)

    def test_exit_before_handshake_cannot_hide_an_independent_host_orphan(self):
        try:
            self.start('orphanBeforeHandshake');report=self.result(125)
            self.assertFalse(report['hostGroupsAuthenticated'])
            self.assertFalse(report['cleanupVerified'])
            self.assertEqual(json.loads(self.state.read_text())['launches'],0)
            self.process=None;self.start();self.result(75)
        finally:
            record=self.sessions/'one/resource-run/child.json'
            if record.exists():
                identity=json.loads(record.read_text())
                self.stop_fixture_host(identity['pid'],identity['starttime'])

    def test_stale_handshake_does_not_admit(self):
        self.start('stale');self.result(125)
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)

    def test_zombie_handshake_does_not_admit(self):
        self.start('zombie');self.result(125)
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)

    def test_signal_during_device_query_never_launches(self):
        self.mutate(blockQuery=True);self.start()
        self.wait(lambda:self.state.with_suffix('.blocked').exists())
        self.process.send_signal(signal.SIGTERM)
        self.result(143)
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)

    def test_package_inventory_has_a_finite_query_budget(self):
        self.start();self.active()
        for _ in range(7):
            self.apps.append(subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'],start_new_session=True))
        self.mutate(pids=[p.pid for p in self.apps]);self.finish()
        report=self.result(125)
        self.assertFalse(report['cleanupVerified'])
        self.assertEqual(json.loads(self.state.read_text())['stops'],0)

    def test_slow_adb_calls_share_one_cleanup_deadline(self):
        self.start();self.active();self.mutate(slowCleanup=True)
        began=time.monotonic();self.finish()
        report=self.result(125)
        self.assertLess(time.monotonic()-began,15)
        self.assertFalse(report['cleanupVerified'])
        self.assertEqual(json.loads(self.state.read_text())['stops'],0)

    def test_am_start_timeout_records_the_exact_command_without_claiming_cleanup(self):
        config=json.loads(self.config.read_text());config['seconds']=2;self.config.write_text(json.dumps(config))
        self.mutate(pids=[self.apps[0].pid],slowAmStart=True)
        self.start();report=self.result(125)
        self.assertEqual(report['error'],'TimeoutExpired')
        self.assertIsInstance(report.get('errorTimeoutSeconds'),(int,float))
        self.assertGreater(report['errorTimeoutSeconds'],0)
        self.assertLessEqual(report['errorTimeoutSeconds'],2)
        self.assertFalse(report['cleanupVerified'])
        self.assertFalse(report['conversionAccepted'])
        state=json.loads(self.state.read_text())
        self.assertEqual(state['stops'],0)
        self.assertTrue(state['active'])
        self.assertEqual(report.get('errorCommand'),[str(self.adb),'-s','fixture-serial',
            'shell','am','start','-W','-n',
            'com.pietrocode.epubtomp3.flutter_app.verification/com.pietrocode.epubtomp3.flutter_app.MainActivity'])

    def test_slow_am_start_within_startup_budget_can_finish_and_cleanup(self):
        self.mutate(slowAmStart=True)
        self.start();self.active()
        self.assertTrue(self.state.with_suffix('.am-returned').exists())
        self.finish();report=self.result(0)
        self.assertTrue(report['started'])
        self.assert_stopped(report)

    def test_signal_during_slow_am_start_cleans_only_after_owned_response(self):
        self.mutate(slowAmStart=True)
        self.start();self.wait(lambda:json.loads(self.state.read_text())['active'])
        self.assertFalse(self.state.with_suffix('.am-returned').exists())
        self.process.send_signal(signal.SIGTERM)
        report=self.result(143)
        self.assertTrue(report['started'])
        self.assert_stopped(report)

    def test_first_postlaunch_ps_timeout_records_the_exact_command(self):
        self.mutate(pids=[self.apps[0].pid],slowFirstPostLaunchPs=True)
        self.start();report=self.result(125)
        self.assertEqual(report['error'],'TimeoutExpired')
        self.assertIsInstance(report.get('errorTimeoutSeconds'),(int,float))
        self.assertGreater(report['errorTimeoutSeconds'],0)
        self.assertLessEqual(report['errorTimeoutSeconds'],3)
        self.assertFalse(report['cleanupVerified'])
        self.assertFalse(report['conversionAccepted'])
        state=json.loads(self.state.read_text())
        self.assertEqual(state['stops'],0)
        self.assertTrue(state['active'])
        self.assertTrue(state['postLaunchPsDelayed'])
        self.assertEqual(report.get('errorCommand'),[str(self.adb),'-s','fixture-serial',
            'shell','ps','-A','-o','PID,UID,NAME'])

    def test_foreign_uid_does_not_launch_or_stop(self):
        self.mutate(foreignUid=True);self.start();self.result(75)
        self.assertEqual(json.loads(self.state.read_text())['stops'],0)

    def assert_kernel_refused(self, condition, expected_error):
        self.mutate(**{condition:True});self.start();self.result(75)
        state=json.loads(self.state.read_text())
        self.assertEqual(state['launches'],0)
        self.assertEqual(state['stops'],0)
        self.assertIn(expected_error,self.stdout)
        calls=[json.loads(line) for line in self.state.with_suffix('.calls').read_text().splitlines()]
        self.assertEqual(calls[-1],['-s','fixture-serial','shell','run-as',state['package'],
                                    'sha256sum','app_flutter/flutter_assets/kernel_blob.bin'])

    def test_missing_appdata_kernel_refuses_launch_and_stop(self):
        self.assert_kernel_refused('kernelMissing','CalledProcessError')

    def test_mismatched_appdata_kernel_refuses_launch_and_stop(self):
        self.assert_kernel_refused('kernelMismatch','ValueError')

    def test_pid_reuse_refuses_stop_and_blocks_next_session(self):
        self.start();self.active();self.mutate(reuse=True);self.finish()
        report=self.result(125);self.assertFalse(report['cleanupVerified'])
        self.assertEqual(json.loads(self.state.read_text())['stops'],0)
        self.process=None;self.start();self.result(75)

    def test_adb_disconnect_is_not_an_empty_inventory(self):
        self.start();self.active();self.mutate(disconnect=True);self.finish()
        self.assertFalse(self.result(125)['cleanupVerified'])

    def test_invalid_inventory_is_not_empty(self):
        self.start();self.active();self.mutate(invalidPs=True);self.finish()
        self.assertFalse(self.result(125)['cleanupVerified'])

    def test_cleanup_same_uid_unknown_name_is_not_empty_inventory(self):
        self.mutate(pids=[self.apps[0].pid])
        self.start();self.active();self.mutate(processNameOverride='renamed-owned-process');self.finish()
        report=self.result(125)
        self.assertFalse(report['cleanupVerified'])
        state=json.loads(self.state.read_text())
        self.assertEqual(state['stops'],0)
        self.assertTrue(state['active'])
        next_session=subprocess.run([sys.executable,str(COORDINATOR),'--config',str(self.config),
            '--state-root',str(self.sessions),'--session-id','two','--sole-executor'],
            env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(next_session.returncode,75,(next_session.stdout,next_session.stderr))
        self.assertFalse((self.sessions/'two').exists())

    def test_prelaunch_same_uid_unknown_name_is_not_inactive_package(self):
        self.mutate(active=True,pids=[self.apps[0].pid],processNameOverride='renamed-owned-process')
        self.start();self.result(75)
        state=json.loads(self.state.read_text())
        self.assertEqual(state['launches'],0)
        self.assertEqual(state['stops'],0)

    def test_force_stop_failure_is_not_success(self):
        self.start();self.active();self.mutate(failStop=True);self.finish()
        self.assertFalse(self.result(125)['cleanupVerified'])

    def test_missing_previous_proof_blocks_start(self):
        self.sessions.mkdir(mode=0o700)
        (self.sessions/'previous').mkdir(mode=0o700)
        self.start();self.result(75)
        self.assertIn('FileNotFoundError',self.stdout)
        self.assertEqual(json.loads(self.state.read_text())['launches'],0)


if __name__ == '__main__':
    unittest.main()
