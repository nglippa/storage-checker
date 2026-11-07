import AppKit
import ImageIO
import UniformTypeIdentifiers

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let shots:[(String,String,String,Bool)] = [
 ("01-storage-overview-dark","See what’s taking up space.","A visual map of the files and folders on your Mac.",true),
 ("02-storage-atlas-light","A clearer view of your disk.","Compare the biggest folders with Storage Atlas.",false),
 ("03-developer-workspace","Find the weight in your workspace.","Explore projects, build output and creative assets.",true),
 ("04-media-library","Explore your media library.","Follow your footage from camera originals to final exports.",false),
 ("05-largest-files","Spot your largest files.","See the files that account for the most indexed storage.",true),
 ("06-largest-folders","Compare folders at a glance.","Bring your largest folders to the top.",false),
 ("07-find-movies","Find files by name.","Search your inventory and see each result in context.",true),
 ("08-size-filter-dim","Keep small files in context.","Highlight folders of at least 1 GB while preserving the structure.",true),
 ("09-size-filter-hide","Show only what matters.","Hide smaller items with a minimum size filter.",false),
 ("10-path-to-root","Follow the path to the root.","Keep the selected folder and its ancestry in view.",true),
 ("11-focus-on-folder","Focus on one folder.","Make a selected branch easier to explore.",false),
 ("12-isolate-a-branch","Explore one branch at a time.","Isolate a path, then return to the wider view.",true),
 ("13-storage-history","See how storage changes.","Review recorded capacity readings throughout the day.",false),
 ("14-recorded-change","Understand what changed.","Inspect the details behind a recorded storage change.",false),
 ("15-compact-explorer","Keep your disk in view.","Explore your inventory in a compact layout.",false)
]
func color(_ value:UInt32)->NSColor { NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1) }
func canvas(_ width:Int,_ height:Int,_ draw:()->Void)->NSBitmapImageRep {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 bitmap.size=CGSize(width:width,height:height)
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
 draw(); NSGraphicsContext.restoreGraphicsState(); return bitmap
}
func text(_ text:String,_ rect:CGRect,_ font:NSFont,_ ink:NSColor) {
 (text as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:ink])
}
func save(_ bitmap:NSBitmapImageRep,_ url:URL) { try! bitmap.representation(using:.png,properties:[:])!.write(to:url) }
var manifest=[[String:Any]]()
for (name,title,subtitle,dark) in shots {
 let source=root.appendingPathComponent("originals/\(name).png")
 guard let image=NSImage(contentsOf:source) else { fatalError("Missing \(source)") }
 let original=NSBitmapImageRep(data:try! Data(contentsOf:source))!
 let bitmap=canvas(3200,2400) {
  let bg=color(dark ? 0x171C21:0xEEECE6),ink=color(dark ? 0xF3F2EC:0x20252A),secondary=color(dark ? 0xAFB5BA:0x596168)
  bg.setFill(); NSRect(x:0,y:0,width:3200,height:2400).fill()
  text("STORAGE MONITOR",CGRect(x:140,y:2280,width:1700,height:42),NSFont.systemFont(ofSize:30,weight:.semibold),secondary)
  text("macOS · 2.3.0",CGRect(x:2720,y:2280,width:340,height:42),NSFont.systemFont(ofSize:30,weight:.medium),secondary)
  text(title,CGRect(x:140,y:2130,width:2920,height:125),NSFont.systemFont(ofSize:86,weight:.semibold),ink)
  text(subtitle,CGRect(x:144,y:2064,width:2900,height:56),NSFont.systemFont(ofSize:36,weight:.regular),secondary)
  let scale=min(2920/CGFloat(original.pixelsWide),1900/CGFloat(original.pixelsHigh))
  let size=CGSize(width:CGFloat(original.pixelsWide)*scale,height:CGFloat(original.pixelsHigh)*scale)
  let frame=CGRect(x:(3200-size.width)/2,y:100+(1900-size.height)/2,width:size.width,height:size.height)
  NSGraphicsContext.saveGraphicsState()
  let shadow=NSShadow(); shadow.shadowColor=NSColor.black.withAlphaComponent(dark ? 0.36:0.18); shadow.shadowBlurRadius=38; shadow.shadowOffset=CGSize(width:0,height:-12); shadow.set()
  color(dark ? 0x30343A:0xBFC2C3).setFill(); NSBezierPath(roundedRect:frame.insetBy(dx:-1,dy:-1),xRadius:16,yRadius:16).fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:frame,xRadius:14,yRadius:14).addClip()
  image.draw(in:frame,from:.zero,operation:.copy,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.high])
  NSGraphicsContext.restoreGraphicsState()
 }
 save(bitmap,root.appendingPathComponent("marketing/\(name).png"))
 manifest.append(["file":name+".png","title":title,"caption":subtitle,"originalWidth":original.pixelsWide,"originalHeight":original.pixelsHigh,"marketingWidth":3200,"marketingHeight":2400,"appearance":dark ? "dark":"light"])
 print("COMPOSE \(name)")
}
let contact=canvas(1800,2450) {
 color(0xE5E3DD).setFill(); NSRect(x:0,y:0,width:1800,height:2450).fill()
 text("Storage Monitor 2.3.0 · Marketing image set",CGRect(x:36,y:2378,width:1728,height:48),NSFont.systemFont(ofSize:32,weight:.semibold),color(0x20252A))
 for (index,shot) in shots.enumerated() {
  let column=index%3,row=index/3
  let x=CGFloat(column)*590+25,y=CGFloat(4-row)*463+35
  let image=NSImage(contentsOf:root.appendingPathComponent("marketing/\(shot.0).png"))!
  image.draw(in:CGRect(x:x,y:y+36,width:570,height:427.5),from:.zero,operation:.copy,fraction:1)
  text("\(index+1). \(shot.1)",CGRect(x:x+5,y:y,width:560,height:29),NSFont.systemFont(ofSize:19,weight:.medium),color(0x30353A))
 }
}
save(contact,root.appendingPathComponent("contact-sheet.png"))
try! JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("shots.json"))
