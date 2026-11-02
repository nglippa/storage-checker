import AppKit

struct Tile: Decodable { let file:String; let title:String; let note:String; let crop:[CGFloat]? }
struct Row: Decodable { let heading:String?; let tiles:[Tile] }
struct Sheet: Decodable { let title:String; let subtitle:String; let output:String; let rows:[Row] }
let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let spec=try JSONDecoder().decode([Sheet].self,from:Data(contentsOf:base.appendingPathComponent(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "layout.json")))
let W:CGFloat=6400,M:CGFloat=120,G:CGFloat=80,labelH:CGFloat=150,rowGap:CGFloat=90
let ink=NSColor(srgbRed:0.12,green:0.15,blue:0.17,alpha:1)
let muted=NSColor(srgbRed:0.36,green:0.40,blue:0.43,alpha:1)
func image(_ tile:Tile)->NSImage { NSImage(contentsOf:base.appendingPathComponent("source-screenshots/"+tile.file))! }
func pixels(_ tile:Tile)->CGSize { let im=image(tile);let rep=im.representations.first!;return CGSize(width:rep.pixelsWide,height:rep.pixelsHigh) }
for sheet in spec {
    let header:CGFloat=570
    var rowHeights=[CGFloat]()
    for row in sheet.rows {
        let cell=(W-2*M-G*CGFloat(row.tiles.count-1))/CGFloat(row.tiles.count)
        let heights=row.tiles.map { tile -> CGFloat in
            let p=pixels(tile);let size=tile.crop.map{CGSize(width:$0[2],height:$0[3])} ?? p
            return size.height * min(1,cell/size.width)
        }
        rowHeights.append((row.heading == nil ? 0 : 100)+labelH+(heights.max() ?? 0)+rowGap)
    }
    let H=header+rowHeights.reduce(0,+)+230
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(W),pixelsHigh:Int(H),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size=CGSize(width:W,height:H)
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let ctx=NSGraphicsContext.current!
    NSColor(srgbRed:0.955,green:0.956,blue:0.944,alpha:1).setFill();NSRect(x:0,y:0,width:W,height:H).fill()
    func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ color:NSColor=ink,_ width:CGFloat=W-2*M) {
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping
        let font=NSFont.systemFont(ofSize:size,weight:weight)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:color,.paragraphStyle:style]
        let r=(string as NSString).boundingRect(with:CGSize(width:width,height:250),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs)
        (string as NSString).draw(in:NSRect(x:x,y:H-y-r.height,width:width,height:r.height+2),withAttributes:attrs)
    }
    func line(_ y:CGFloat) {NSColor(white:0.73,alpha:1).setFill();NSRect(x:M,y:H-y,width:W-2*M,height:2).fill()}
    text("STORAGE MONITOR V2  /  DESIGN-LED UX OVERHAUL  /  28 OCT 2026",M,90,30,.semibold,muted)
    text(sheet.title,M,155,92,.semibold)
    text(sheet.subtitle,M,280,38,.regular,ink)
    text("ALL IMAGES: HEADLESS OFFSCREEN NATIVE VIEW RENDERS · NOT NATIVE WINDOW CAPTURES · 2× PIXELS · \"BEFORE\" TILES = PRIOR UX MILESTONE",M,355,29,.semibold,muted)
    text("Real preserved QA catalog, 22 Oct 2026 · live capacity is current · title bar and toolbar absent · no desktop input or cleanup",M,410,28,.regular,muted)
    line(490)
    var y=header
    for (idx,row) in sheet.rows.enumerated() {
        if let heading=row.heading {text(heading,M,y,44,.semibold);y+=100}
        let cell=(W-2*M-G*CGFloat(row.tiles.count-1))/CGFloat(row.tiles.count)
        let maxH=rowHeights[idx]-(row.heading == nil ? 0 : 100)-labelH-rowGap
        for (j,tile) in row.tiles.enumerated() {
            let x=M+CGFloat(j)*(cell+G)
            text(tile.title,x,y,37,.semibold,ink,cell)
            text(tile.note,x,y+58,27,.regular,muted,cell)
            let im=image(tile),p=pixels(tile)
            let crop=tile.crop
            let size=crop.map{CGSize(width:$0[2],height:$0[3])} ?? p
            let scale=min(1,cell/size.width),dw=size.width*scale,dh=size.height*scale
            let r=NSRect(x:x,y:H-(y+labelH)-dh,width:dw,height:dh)
            // Source rectangles use the image's own point dimensions, preserving pixel proportions.
            let source:NSRect
            if let c=crop {let sx=im.size.width/p.width,sy=im.size.height/p.height;source=NSRect(x:c[0]*sx,y:(p.height-c[1]-c[3])*sy,width:c[2]*sx,height:c[3]*sy)}
            else {source=NSRect(origin:.zero,size:im.size)}
            ctx.imageInterpolation = .high
            im.draw(in:r,from:source,operation:.copy,fraction:1,respectFlipped:false,hints:nil)
            NSColor(white:0.68,alpha:1).setStroke();let border=NSBezierPath(rect:r);border.lineWidth=1;border.stroke()
        }
        y+=labelH+maxH+rowGap
    }
    line(H-170)
    text("REVIEW LIMITS  Native title bar, toolbar, popover placement, pointer behaviour and keyboard focus are NOT VERIFIED by these renders.",M,H-140,26,.medium,muted)
    text("Original PNGs and provenance accompany this sheet. Components and close-ups are labelled; full frames retain clipping and empty space.",M,H-92,26,.regular,muted)
    NSGraphicsContext.current=nil
    try rep.representation(using:.png,properties:[:])!.write(to:base.appendingPathComponent(sheet.output))
    print("WROTE \(sheet.output) \(Int(W))x\(Int(H))")
}
