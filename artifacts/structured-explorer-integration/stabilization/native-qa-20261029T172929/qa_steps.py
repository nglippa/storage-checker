from pathlib import Path
import json,subprocess,time
m=json.loads(Path('/private/tmp/storage-native-current.json').read_text());o=Path(m['out']);g=str(o/'safety-guard');pid=str(m['pid']);wid='70508'
def run(a):
 r=subprocess.run([g]+a,capture_output=True,text=True)
 if r.returncode:raise RuntimeError('SAFETY STOP '+r.stdout+r.stderr)
 return json.loads(r.stdout)
def dump(name):
 d=run(['dump',pid]);(o/(name+'-ax.json')).write_text(json.dumps(d,indent=2));return d

def inp(kind,x=0,y=0,*args):
 r=run(['input',pid,kind,str(x),str(y)]+list(map(str,args)))
 with (o/'inputs.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
 return r

def match(d,**attrs):
 return next(e for e in d['elements'] if all(e.get(k)==v for k,v in attrs.items()) and e['frame']['w']>0)
def click(e,count=1):
 f=e['frame'];return inp('click',f['x']+f['w']/2,f['y']+f['h']/2,count)
def cap(name):
 run(['guard',pid]);subprocess.run(['/usr/sbin/screencapture','-x','-l',wid,str(o/(name+'.png'))],check=True)
def summary(d):
 return [e for e in d['elements'] if e.get('id') in ['inventory.breadcrumbs','inventory.status'] or e.get('description','').startswith('Structured Explorer of') or str(e.get('value','')).startswith('Zoom ')]
def waitroot(root,name):
 end=time.time()+5
 while time.time()<end:
  d=dump(name)
  if any(e.get('description')=='Structured Explorer of '+root for e in d['elements']):return d
  time.sleep(.04)
 raise RuntimeError('root did not settle '+root)
