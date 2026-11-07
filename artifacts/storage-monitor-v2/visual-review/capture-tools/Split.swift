import AppKit

// Splits each composed collage into one JPEG per headed section (continuation rows stay with their section),
// using the same row geometry as Compose.swift. Pixels are copied, never rescaled.
struct Tile: Decodable { let file:String; let crop:[CGFloat]? }
struct Row: Decodable { let heading:String?; let tiles:[Tile] }
struct Sheet: Decodable { let output:String; let rows:[Row] }
let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let out=base.appendingPathComponent("upload",isDirectory:true)
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let spec=try JSONDecoder().decode([Sheet].self,from:Data(contentsOf:base.appendingPathComponent("layout.json")))
let W:CGFloat=6400,M:CGFloat=120,G:CGFloat=80,labelH:CGFloat=150,rowGap:CGFloat=90,header:CGFloat=570
func pixels(_ tile:Tile)->CGSize { let rep=NSImage(contentsOf:base.appendingPathComponent("source-screenshots/"+tile.file))!.representations.first!;return CGSize(width:rep.pixelsWide,height:rep.pixelsHigh) }
for (sheetIndex,sheet) in spec.enumerated() {
    let full=NSBitmapImageRep(data:try Data(contentsOf:base.appendingPathComponent(sheet.output)))!.cgImage!
    var sections=[(start:CGFloat,end:CGFloat)](), y=header
    for row in sheet.rows {
        let cell=(W-2*M-G*CGFloat(row.tiles.count-1))/CGFloat(row.tiles.count)
        let tallest=row.tiles.map { tile -> CGFloat in let s=tile.crop.map{CGSize(width:$0[2],height:$0[3])} ?? pixels(tile);return s.height*min(1,cell/s.width) }.max() ?? 0
        let height=(row.heading == nil ? 0 : 100)+labelH+tallest+rowGap
        if row.heading != nil || sections.isEmpty { sections.append((y,y+height)) } else { sections[sections.count-1].end=y+height }
        y+=height
    }
    sections[0].start=0   // the first section carries the sheet title and capture labels
    for (index,section) in sections.enumerated() {
        let rect=CGRect(x:0,y:section.start,width:W,height:min(CGFloat(full.height),section.end)-section.start)
        let piece=NSBitmapImageRep(cgImage:full.cropping(to:rect)!)
        let name=String(format:"v2-collage-%d-part-%02d.jpg",sheetIndex+1,index+1)
        try piece.representation(using:.jpeg,properties:[.compressionFactor:0.86])!.write(to:out.appendingPathComponent(name))
        print("WROTE upload/\(name) \(Int(rect.width))x\(Int(rect.height))")
    }
}
