import sys,time,json,subprocess
sys.path.insert(0,'/private/tmp');from qa_steps import *
start=time.time();rows=[];i=0
try:
 while time.time()-start<120:
  d=dump('operator-state-%02d'%i)
  rows.append({'unix':time.time(),'summary':summary(d),'identity':d['identity']})
  if i%5==0:cap('operator-%02d'%i)
  i+=1;time.sleep(2)
except Exception as e:rows.append({'stopped':str(e),'unix':time.time()})
finally:
 (o/'operator-observations.json').write_text(json.dumps(rows,indent=2))
 (o/'finish-request').touch()
 print(json.dumps({'passive_seconds':time.time()-start,'samples':i,'automatic_input_sent':False}),flush=True)
