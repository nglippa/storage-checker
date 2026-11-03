import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor private func until(_ test: () -> Bool) async {
    let end = Date().addingTimeInterval(15)
    while !test(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
}

@main struct MarketingCapture {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let database=CommandLine.arguments[1], output=URL(fileURLWithPath:CommandLine.arguments[2])
        var preferences:[String:Any] = ["inventory.explorer.visualization":"tree","inventory.explorer.inspector":true,"inventory.explorer.treeNavigatorExpanded":false,"inventory.explorer.showMap":true,"inventory.explorer.mapHeight":570.0,"inventory.livingTree.renderer":"structured","inventory.structuredExplorer.depth":4]
        func prefer(_ key:String,_ value:Any) {
            preferences[key]=value
            UserDefaults.standard.setVolatileDomain(preferences, forName:UserDefaults.argumentDomain)
            ViewerStore.viewPreferences.setVolatileDomain(preferences, forName:UserDefaults.argumentDomain)
        }
        prefer("inventory.livingTree.renderer","structured")
        let config=ViewerConfiguration(database:database,appearance:nil,windowSize:nil,isQA:false,readinessOutput:nil)
        let history=ViewerStore(configuration:config)
        await history.live.refresh()
        history.refresh(); await until { history.snapshot != nil }
        let browser=InventoryBrowserModel(database:database,readiness:ViewerReadiness(output:nil))
        await browser.load()
        let root=browser.directory!, explorer=browser.explorer, tree=browser.livingTree, state=browser.structuredExplorer
        func show(_ node:InventoryNode) async {
            state.resetFilters(); browser.navigate(node); await browser.load()
            explorer.show(root:browser.directory ?? node,trail:browser.breadcrumbs)
            tree.show(root:browser.directory ?? node,trail:browser.breadcrumbs)
            await until { tree.model?.root.id == node.id && explorer.state.children[node.id] != nil }
            explorer.selection=nil
        }
        await show(root)
        func node(_ name:String) async -> InventoryNode {
            let all=try! await browser.reader.search(text:name,limit:100)
            return all.items.first { $0.name == name }!
        }
        func choose(_ name:String) async -> InventoryNode {
            let target=await node(name)
            let chain=try! await browser.reader.breadcrumbs(id:target.id)
            explorer.select(target,through:Array(chain.dropFirst().dropLast()))
            await until { explorer.state.node(target.id) != nil }
            return target
        }
        func save<V:View>(_ name:String,dark:Bool=true,size:CGSize=CGSize(width:1440,height:960),view:V) async {
            let window=NSWindow(contentRect:CGRect(x:-20000,y:-20000,width:size.width,height:size.height),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            NSApp.appearance=window.appearance
            let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).environment(\.colorScheme,dark ? .dark:.light).transaction { $0.disablesAnimations=true })
            host.frame=CGRect(origin:.zero,size:size); window.contentView=host
            for _ in 0..<18 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for:.milliseconds(50)) }
            guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width*2),pixelsHigh:Int(size.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { fatalError("No bitmap") }
            rep.size=size
            window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in:host.bounds,to:rep) }
            guard let cg=rep.cgImage,let destination=CGImageDestinationCreateWithURL(output.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("No image") }
            CGImageDestinationAddImage(destination,cg,nil); precondition(CGImageDestinationFinalize(destination))
            print("CAPTURE \(name) \(cg.width)x\(cg.height)")
            window.contentView=nil
        }
        func disk(_ name:String,dark:Bool=true,size:CGSize=CGSize(width:1440,height:960)) async {
            await save(name,dark:dark,size:size,view:DiskInventoryView(configuration:config,history:history,model:browser))
        }
        await disk("01-storage-overview-dark")
        prefer("inventory.explorer.visualization","atlas")
        await disk("02-storage-atlas-light",dark:false)
        prefer("inventory.explorer.visualization","tree")
        await show(await node("Projects")); _ = await choose("Aurora Website")
        await disk("03-developer-workspace")
        await show(await node("Movies")); _ = await choose("Coastline Film")
        await disk("04-media-library",dark:false)
        await show(root); browser.mode = .files; await browser.load()
        await disk("05-largest-files")
        browser.mode = .directories; await browser.load()
        await disk("06-largest-folders",dark:false)
        browser.mode = .all; browser.search = "coastline"; await browser.load()
        await disk("07-find-movies",size:CGSize(width:1200,height:720))
        browser.search=""; browser.mode = .explorer; await show(await node("Projects"))
        state.filter.minimumBytes=1_000_000_000
        await disk("08-size-filter-dim")
        state.filter.minimumBytes=5_000_000_000; state.filter.presentation = .hide
        await disk("09-size-filter-hide",dark:false)
        state.resetFilters(); _ = await choose("assets"); state.filter.focus = .path
        await disk("10-path-to-root")
        state.resetFilters(); _ = await choose("Aurora Website"); state.filter.focus = .subtree
        await disk("11-focus-on-folder",dark:false)
        state.resetFilters(); let target=await choose("Aurora Website")
        if let model=tree.model { state.isolate(.node(target.id),model:model,selection:target.id) }
        await disk("12-isolate-a-branch")
        await save("13-storage-history",dark:false,view:HistoryView(store:history))
        history.selection="reading:21"
        history.showInspector=true
        await save("14-recorded-change",dark:false,view:HistoryView(store:history))
        await show(root)
        prefer("inventory.explorer.inspector",false)
        await disk("15-compact-explorer",dark:false,size:CGSize(width:1100,height:780))
        print("DONE 15 exact-source captures")
    }
}
