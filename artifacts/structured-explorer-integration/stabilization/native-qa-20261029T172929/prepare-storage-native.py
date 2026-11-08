from pathlib import Path
import datetime,json,subprocess,tempfile,hashlib,os
repo=Path('/Users/nicholaslippa/storage-checker-structured-explorer')
out=repo/'artifacts/structured-explorer-integration/stabilization'/('native-qa-'+datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
out.mkdir(mode=0o700)
s= (repo/'artifacts/structured-explorer-integration/native-qa/safety-guard.swift').read_text().replace('addingTimeInterval(600)','addingTimeInterval(720)').replace('ten-minute deadline','twelve-minute deadline')
s=s.replace('default: exit(2)',r'''case "input":
    let pid=Int32(args[2])!
    let(ok,data,_)=verify(pid);guard ok else {output(data);exit(41)}
    let kind=args[3], point=CGPoint(x:Double(args[4])!,y:Double(args[5])!)
    output(["action":kind,"x":point.x,"y":point.y,"time":Date().timeIntervalSince1970,"identity":data])
    func post(_ e:CGEvent?) {guard let e else {exit(42)};e.post(tap:.cghidEventTap)}
    if kind=="move" {post(CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left))}
    if kind=="click" {
        let count=Int(args[6])!
        for n in 1...count {
            let(ok,_,_)=verify(pid);guard ok else{exit(41)}
            for t:CGEventType in [.leftMouseDown,.leftMouseUp] {
                let e=CGEvent(mouseEventSource:nil,mouseType:t,mouseCursorPosition:point,mouseButton:.left)!
                e.setIntegerValueField(.mouseEventClickState,value:Int64(n));post(e);Thread.sleep(forTimeInterval:0.025)
            }
            Thread.sleep(forTimeInterval:0.06)
        }
    }
    if kind=="key" {
        for down in [true,false] {post(CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(Int(args[6])!),keyDown:down))}
    }
    if kind=="scroll" {
        post(CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left));Thread.sleep(forTimeInterval:0.05)
        let e=CGEvent(scrollWheelEvent2Source:nil,units:args[7]=="line" ? .line:.pixel,wheelCount:2,wheel1:Int32(args[6])!,wheel2:Int32(args[8])!,wheel3:0)!
        if args.count>9 {e.flags=CGEventFlags(rawValue:UInt64(args[9])!)};post(e)
    }
default: exit(2)''')
(out/'safety-guard.swift').write_text(s)
subprocess.run(['swiftc',str(out/'safety-guard.swift'),'-o',str(out/'safety-guard')],check=True,capture_output=True)
tmp=Path(tempfile.mkdtemp(prefix='storage-stabilization-qa-',dir='/private/tmp'));os.chmod(tmp,0o700)
snapshot=Path('/Users/nicholaslippa/storage-checker/build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3')
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
 return h.hexdigest()
before=sha(snapshot)
subprocess.run(['cp','-c',str(snapshot),str(tmp/'structured-explorer-native.sqlite3')],check=True)
subprocess.run([str(out/'safety-guard'),'snapshot',str(out/'preferences-before.plist')],check=True)
meta={'out':str(out),'tmp':str(tmp),'snapshot':str(snapshot),'snapshot_sha256_before':before,'bundle':'local.macbook.storage-monitor.viewer.dev','window_title':'Storage Monitor — QA: structured-explorer-native.sqlite3','authorization':'User: go for QA; continue','app':str(repo/'build/Storage Monitor.app')}
(out/'preflight.json').write_text(json.dumps(meta,indent=2))
Path('/private/tmp/storage-native-current.json').write_text(json.dumps(meta))
print(json.dumps(meta,indent=2))
