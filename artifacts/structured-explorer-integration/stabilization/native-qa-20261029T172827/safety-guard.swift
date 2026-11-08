import AppKit
import ApplicationServices
import Foundation
let args = CommandLine.arguments
let suite = "local.macbook.storage-monitor.viewer.qa"
let expectedBundle = "local.macbook.storage-monitor.viewer.dev"
let expectedTitle = "Storage Monitor — QA: structured-explorer-native.sqlite3"
func output(_ value: Any) { let d = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); print(String(data:d,encoding:.utf8)!) }
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }; return value }
func point(_ element: AXUIElement) -> [String:Double] { var p=CGPoint.zero; if let a=attr(element,kAXPositionAttribute),CFGetTypeID(a)==AXValueGetTypeID() { AXValueGetValue(a as! AXValue,.cgPoint,&p) }; var s=CGSize.zero; if let a=attr(element,kAXSizeAttribute),CFGetTypeID(a)==AXValueGetTypeID() { AXValueGetValue(a as! AXValue,.cgSize,&s) }; return ["x":p.x,"y":p.y,"w":s.width,"h":s.height] }
func verify(_ pid: Int32) -> (Bool,[String:Any],AXUIElement?) {
    guard let front=NSWorkspace.shared.frontmostApplication else { return(false,["reason":"no frontmost application"],nil) }
    var data:[String:Any] = ["pid":front.processIdentifier,"bundle":front.bundleIdentifier ?? "", "time":Date().timeIntervalSince1970]
    guard front.processIdentifier==pid,front.bundleIdentifier==expectedBundle else { data["reason"]="focus left authorized PID/bundle"; return(false,data,nil) }
    let app=AXUIElementCreateApplication(pid)
    guard let w=attr(app,kAXFocusedWindowAttribute), CFGetTypeID(w)==AXUIElementGetTypeID() else { data["reason"]="no focused QA window"; return(false,data,nil) }
    let window=w as! AXUIElement, title=attr(window,kAXTitleAttribute) as? String ?? ""
    data["title"]=title; data["frame"]=point(window)
    guard title==expectedTitle else { data["reason"]="focused window is not authorized title"; return(false,data,nil) }
    return(true,data,window)
}
func restore(_ path:String) {
    if let d=NSDictionary(contentsOfFile:path) as? [String:Any] { UserDefaults(suiteName:suite)!.setPersistentDomain(d,forName:suite); UserDefaults(suiteName:suite)!.synchronize() }
}
switch args[1] {
case "snapshot":
    let d=UserDefaults(suiteName:suite)!.persistentDomain(forName:suite) ?? [:]
    (d as NSDictionary).write(toFile:args[2],atomically:true); chmod(args[2],0o600)
    output(["suite":suite,"keys":d.count])
case "set":
    let d=UserDefaults(suiteName:suite)!; d.set(args[3],forKey:args[2]); d.synchronize(); output(["set":args[2],"value":args[3]])
case "restore": restore(args[2]); output(["restored":suite])
case "activate":
    guard let a=NSRunningApplication(processIdentifier:Int32(args[2])!),a.bundleIdentifier==expectedBundle else { exit(41) }
    a.activate(options:[])
case "guard":
    let (ok,data,_)=verify(Int32(args[2])!);output(data);exit(ok ? 0:41)
case "dump":
    let (ok,data,window)=verify(Int32(args[2])!);guard ok,let window else { output(data);exit(41) }
    var rows=[[String:Any]]()
    func walk(_ e:AXUIElement,_ depth:Int) { guard depth<12, rows.count<2000 else{return};let role=attr(e,kAXRoleAttribute) as? String ?? "";var r:[String:Any] = ["role":role,"frame":point(e)]
        for (k,a) in [("title",kAXTitleAttribute),("description",kAXDescriptionAttribute),("value",kAXValueAttribute),("id",kAXIdentifierAttribute)] { if let v=attr(e,a) { if let t=v as? String {r[k]=t};if let n=v as? NSNumber {r[k]=n} } }
        rows.append(r); if let children=attr(e,kAXChildrenAttribute) as? [AXUIElement] { for c in children { walk(c,depth+1) } }
    }
    walk(window,0);output(["identity":data,"elements":rows])
case "resize":
    let(ok,data,w)=verify(Int32(args[2])!); guard ok,let w else {output(data);exit(41)}
    var size=CGSize(width:Double(args[3])!,height:Double(args[4])!);let value=AXValueCreate(.cgSize,&size)!
    let result=AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,value);output(["result":result.rawValue,"frame":point(w)])
case "watch":
    let pid=Int32(args[2])!, directory=args[3], deadline=Date().addingTimeInterval(720)
    var reason="twelve-minute deadline",last:[String:Any]=[:]
    while Date()<deadline {
        if FileManager.default.fileExists(atPath:directory+"/finish-request") {reason="requested completion";break}
        if kill(pid,0) != 0 {reason="QA process exited";break}
        let(ok,data,_)=verify(pid);last=data
        if !ok {reason="focus safety stop";break}
        Thread.sleep(forTimeInterval:0.1)
    }
    let record:[String:Any] = ["reason":reason,"last_identity":last,"ended_unix":Date().timeIntervalSince1970]
    let d=try! JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]);try!d.write(to:URL(fileURLWithPath:directory+"/stopped.json"))
    if kill(pid,0)==0 {kill(pid,SIGTERM)}
    for _ in 0..<50 {if kill(pid,0) != 0 {break};Thread.sleep(forTimeInterval:0.1)}
    restore(directory+"/preferences-before.plist")
    try! Data("restored QA preference snapshot\n".utf8).write(to:URL(fileURLWithPath:directory+"/restored.txt"))
case "input":
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
default: exit(2)
}
