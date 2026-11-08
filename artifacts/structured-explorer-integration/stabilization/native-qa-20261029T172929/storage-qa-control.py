from pathlib import Path
import json,subprocess,sys,time
m=json.loads(Path('/private/tmp/storage-native-current.json').read_text());o=Path(m['out']);g=str(o/'safety-guard');pid=str(m['pid'])
def run(a):
 r=subprocess.run([g]+a,capture_output=True,text=True)
 if r.returncode:raise SystemExit('SAFETY STOP '+r.stdout+r.stderr)
 return json.loads(r.stdout)
cmd=sys.argv[1]
if cmd=='dump':
 d=run(['dump',pid]);name=sys.argv[2];(o/(name+'-ax.json')).write_text(json.dumps(d,indent=2))
 print(json.dumps(d['identity']))
 for i,e in enumerate(d['elements']):
  if any(k in e for k in ['title','value','description','id']):print(i,json.dumps(e,ensure_ascii=False))
elif cmd=='input':
 r=run(['input',pid]+sys.argv[2:]);print(json.dumps(r));
 with (o/'inputs.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
elif cmd=='guard':print(json.dumps(run(['guard',pid])))
elif cmd=='capture':
 run(['guard',pid]);subprocess.run(['/usr/sbin/screencapture','-x','-l',sys.argv[2],str(o/(sys.argv[3]+'.png'))],check=True);print(str(o/(sys.argv[3]+'.png')))
elif cmd=='resize':print(run(['resize',pid]+sys.argv[2:]))
elif cmd=='finish':(o/'finish-request').touch()
