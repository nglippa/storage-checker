#!/usr/bin/env python3
"""Headless native QA boundary checks. Never calls open, NSApplication or desktop automation."""
from pathlib import Path
import ctypes,fcntl,hashlib,json,os,signal,subprocess,sys,time,uuid
repo=Path(__file__).resolve().parents[1];root=repo/'build/native-acceptance/runtime';e=repo/'build/native-acceptance/runtime-implementation-evidence';exe=root/'Storage Monitor QA.app/Contents/MacOS/StorageMonitorViewer';helper=root/'bin/StorageMonitor'
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(root/'Temporary')+'/','SQLITE_TMPDIR':str(root/'Temporary')}
records=[]
def run(label,command,environment=env,timeout=10):
 started=time.monotonic();p=subprocess.run(command,cwd='/private/tmp',env=environment,capture_output=True,text=True,timeout=timeout);record={'label':label,'argv':list(map(str,command)),'cwd':'/private/tmp','exit_code':p.returncode,'seconds':time.monotonic()-started,'stdout':p.stdout,'stderr':p.stderr};records.append(record);(e/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');return p
count=0
def check(value,message):
 global count
 if not value:raise RuntimeError(message)
 count+=1;print('PASS '+message,flush=True)
def worker(label='worker-initialization'):
 return run(label,[str(helper),'inventory-work','--qa-runtime-root',str(root),'--qa-owner-pid',str(os.getpid())])
def snap(path):
 if not path.exists():return {'absent':True}
 s=path.lstat();return {'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'mode':s.st_mode&0o777,'size':s.st_size}
prefs=Path.home()/'Library/Preferences/local.macbook.storage-monitor.viewer.plist';before=snap(prefs)
try:
 p=worker();check(p.returncode in [0,75],'actual bounded pinned helper initializes only fixture catalog')
 p=run('bootstrap-verify',[str(exe),'--qa-runtime-root',str(root),'--qa-verify-only']);check(p.returncode==0,'actual QA executable verifies before native lifecycle from unrelated working directory')
 data=json.loads(p.stdout);check(data['bundle_identifier']=='local.macbook.storage-monitor.viewer.native-qa' and data['qa_preference_readback'],'actual QA preference domain readback')
 check(data['nsapplication_initialized'] is False and data['native_window_launched'] is False,'bootstrap probe did not initialize NSApplication')
 check(data['sqlite_vfs_temporary_filename'].startswith(str(root/'Temporary')+'/'),'actual SQLite VFS temporary filename inside QA temporary directory')
 check(data['destinations']['root']==str(root) and data['destinations']['catalog']==str(root/'ApplicationSupport/history.sqlite3'),'actual runtime path manifest uses exact anchored QA root')
 check(before==snap(prefs),'production viewer preference file unchanged across QA probe')
 for label,args,extra in [
  ('refuse-missing-optin',[],{}),('refuse-legacy-db-bypass',['--database-path',str(root/'ApplicationSupport/history.sqlite3')],{}),
  ('refuse-wrong-root',['--qa-runtime-root',str(root)+'/../runtime','--qa-verify-only'],{}),
  ('refuse-env-override',['--qa-runtime-root',str(root),'--qa-verify-only'],{'STORAGE_MONITOR_QA_ROOT':'/private/tmp/forbidden'}),
  ('refuse-home-override',['--qa-runtime-root',str(root),'--qa-verify-only'],{'HOME':'/private/tmp/forbidden'}),
  ('refuse-wrong-sqlite-temp',['--qa-runtime-root',str(root),'--qa-verify-only'],{'SQLITE_TMPDIR':'/private/tmp'}),
 ]:
  p=run(label,[str(exe)]+args,{**env,**extra});check(p.returncode==78 and 'QA runtime refused' in p.stderr,label+' exits before GUI')
 # The application lock is an advisory process-owned lock, not a stale PID recovery action.
 with (root/'ApplicationSupport/viewer-session.lock').open('a+b') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  p=run('refuse-concurrent-session',[str(exe),'--qa-runtime-root',str(root),'--qa-verify-only']);check(p.returncode==78 and 'session holds' in p.stderr,'second actual QA session refuses without killing another process')
 p=worker('worker-after-bootstrap');check(p.returncode in [0,75],'worker services contained bootstrap mailbox request')
 outside=e/'outside-disposable.txt';outside.write_text('Do not index or mutate this disposable outside-root fixture.\n');outside_before=snap(outside)
 request=root/'ApplicationSupport/inventory-requests'/(str(uuid.uuid4())+'.json');request.write_text(json.dumps({'id':str(uuid.uuid4()),'action':'refresh','path':str(outside),'requestedAt':time.time()-978307200,'boundary':None}));request.chmod(0o600)
 p=worker('worker-refuse-outside-request');check(p.returncode not in [0,75] and 'outside fixtures' in p.stderr,'actual worker refuses outside-root mailbox request')
 check(outside_before==snap(outside),'outside disposable fixture unchanged')
 archive=e/'rejected-request-preserved.json';request.rename(archive) # Preserve malformed test state; never delete arbitrary requests.
 p=worker('worker-after-preserved-rejection');check(p.returncode in [0,75],'worker resumes after operator-test rejection is archived explicitly')
 # Explicit cancellation affects only the child Process created by this harness.
 cmd=[str(helper),'inventory-work','--qa-runtime-root',str(root),'--qa-owner-pid',str(os.getpid())]
 child=subprocess.Popen(cmd,cwd='/private/tmp',env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 time.sleep(0.02);started=time.monotonic()
 if child.poll() is None:child.terminate()
 output,error=child.communicate(timeout=6);elapsed=time.monotonic()-started
 (e/'worker-cancellation.json').write_text(json.dumps({'pid':child.pid,'exit_code':child.returncode,'seconds_after_request':elapsed,'stdout':output,'stderr':error},indent=2)+'\n');check(elapsed<6 and child.poll() is not None,'owned helper cancellation exits and is reaped within bound')
 # Direct owner exits while its exact child starts; child must refuse/reap rather than persist.
 ownercode='import os,subprocess,json; p=subprocess.Popen('+repr([str(helper),'inventory-work','--qa-runtime-root',str(root)])+'+["--qa-owner-pid",str(os.getpid())],env='+repr(env)+',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid,flush=True); os._exit(0)'
 owner=subprocess.run([sys.executable,'-B','-c',ownercode],env=env,capture_output=True,text=True,timeout=5);pid=int(owner.stdout.strip());started=time.monotonic();alive=True
 while time.monotonic()-started<6:
  p=subprocess.run(['/bin/ps','-p',str(pid),'-o','stat=,comm='],capture_output=True,text=True)
  if p.returncode!=0 or not p.stdout.strip() or p.stdout.strip().startswith('Z'):alive=False;break
  time.sleep(0.1)
 (e/'worker-owner-death.json').write_text(json.dumps({'owned_child_pid':pid,'owner_exit':owner.returncode,'not_running_after_seconds':time.monotonic()-started,'child_still_running':alive},indent=2)+'\n');check(not alive,'actual child does not remain running after direct owner death')
 check(before==snap(prefs),'production viewer preference file unchanged after negative/lifecycle checks')
 result={'status':'PASS','assertions':count,'native_window_verified':False,'finder_put_back_verified':False,'records':records}
except BaseException as error:
 result={'status':'FAIL','passed_assertions':count,'error':str(error),'records':records};(e/'headless-integration-results.json').write_text(json.dumps(result,indent=2)+'\n');raise
(e/'headless-integration-results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':'PASS','assertions':count}))
