from pathlib import Path
import json,subprocess,time,hashlib,shutil,plistlib
m=json.loads(Path('/private/tmp/storage-native-current.json').read_text());o=Path(m['out']);t=Path(m['tmp']);guard=str(o/'safety-guard')
args=[m['app']+'/Contents/MacOS/StorageMonitorViewer','--database-path',str(t/'structured-explorer-native.sqlite3'),'--window-size','1440x900','-appearance','dark','-inventory.explorer.visualization','tree','-inventory.explorer.treeNavigatorExpanded','true','-inventory.explorer.inspector','true','-inventory.explorer.mapHeight','600','-inventory.structuredExplorer.depth','3','--perf-log',str(o/'native-performance.log'),'-chartRange','Last 30 Days']
subprocess.run(['/usr/bin/open','-n',m['app'],'--args']+args[1:],check=True)
for _ in range(100):
 rows=subprocess.check_output(['/bin/ps','-axo','pid=,command='],text=True).splitlines()
 matches=[int(row.split(None,1)[0]) for row in rows if args[0] in row and str(t/'structured-explorer-native.sqlite3') in row]
 if matches:break
 time.sleep(.1)
else:raise RuntimeError('No launched QA PID')
class OwnedProcess:
 pid=matches[0]
 def poll(self):
  try:__import__('os').kill(self.pid,0);return None
  except ProcessLookupError:return 0
 def terminate(self):__import__('os').kill(self.pid,15)
 def kill(self):__import__('os').kill(self.pid,9)
 def wait(self,timeout=5):
  end=time.time()+timeout
  while self.poll()==None and time.time()<end:time.sleep(.1)
  if self.poll()==None:raise subprocess.TimeoutExpired('QA',timeout)
p=OwnedProcess()
m.update(pid=p.pid,arguments=args,started_unix=time.time(),deadline_unix=time.time()+720)
(o/'session.json').write_text(json.dumps(m,indent=2));Path('/private/tmp/storage-native-current.json').write_text(json.dumps(m))
try:
 for _ in range(300):
  q=subprocess.run([guard,'guard',str(p.pid)],capture_output=True,text=True)
  if q.returncode==0:break
  if p.poll()!=None:raise RuntimeError('QA exited during launch')
  time.sleep(.1)
 else:raise RuntimeError('QA never became authorized frontmost window')
 (o/'launch-identity.json').write_text(q.stdout)
 print(json.dumps({'launched':p.pid,'out':str(o),'identity':json.loads(q.stdout)}),flush=True)
 subprocess.run([guard,'watch',str(p.pid),str(o)],stdout=(o/'guard-output.log').open('w'),stderr=subprocess.STDOUT,check=True)
finally:
 if p.poll()==None:
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 subprocess.run([guard,'restore',str(o/'preferences-before.plist')],check=True)
 subprocess.run([guard,'snapshot',str(o/'preferences-after.plist')],check=True)
 equal=plistlib.loads((o/'preferences-before.plist').read_bytes())==plistlib.loads((o/'preferences-after.plist').read_bytes())
 h=hashlib.sha256()
 with open(m['snapshot'],'rb') as f:
  for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
 after=h.hexdigest()
 # Only this unique mkdtemp tree created for this authorized session is removed.
 shutil.rmtree(t)
 result={'pid_exited':p.poll()!=None,'preferences_restored_equal':equal,'snapshot_sha256_after':after,'snapshot_unchanged':after==m['snapshot_sha256_before'],'clone_removed':not t.exists(),'ended_unix':time.time()}
 (o/'cleanup.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
