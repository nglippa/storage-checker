import SwiftUI
import AppKit

@MainActor func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@MainActor func waitFor(_ seconds: Double = 40, _ predicate: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !predicate() { if Date() > end { return false }; try? await Task.sleep(for: .milliseconds(80)) }
    return true
}
func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) } }

@MainActor final class CaptureHost {
    let window: NSWindow
    let root: NSView
    init<V: View>(_ view: V, _ w: CGFloat, _ h: CGFloat, _ dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        root = NSHostingView(rootView: view.frame(width: w, height: h).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light).environment(\.livingTreeInteractive, false))
        root.frame = NSRect(x: 0,y: 0,width: w,height: h)
        window = NSWindow(contentRect: NSRect(x: -30000,y: -30000,width: w,height: h),styleMask: [.borderless],backing: .buffered,defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("main.visual-review")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = appearance; root.appearance = appearance; window.contentView = root
        root.layoutSubtreeIfNeeded()
    }
    func capture(_ path: String) {
        root.layoutSubtreeIfNeeded(); pump(0.3)
        let w = Int(root.bounds.width), h = Int(root.bounds.height)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w*2,pixelsHigh:h*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size = root.bounds.size
        window.appearance!.performAsCurrentDrawingAppearance { root.cacheDisplay(in:root.bounds,to:bitmap) }
        try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
        precondition(!window.isVisible, "Capture window must never be visible")
        print("CAPTURE \(path) \(w*2)x\(h*2) visible=false",terminator:"\n"); fflush(stdout)
    }
    deinit { }
}

@main struct VisualCapture {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args=CommandLine.arguments
        let db=args[args.firstIndex(of:"--database-path")!+1], out=args[args.firstIndex(of:"--output")!+1]
        let config=ViewerConfiguration(database:db,appearance:nil,windowSize:nil,isQA:true,readinessOutput:nil)
        var captureDefaults = [String:Any]()
        func defaults(_ d: [String:Any]) { captureDefaults.merge(d) { _, new in new }; UserDefaults.standard.setVolatileDomain(captureDefaults, forName: UserDefaults.argumentDomain) }
        defaults(["inventory.explorer.visualization":"atlas","inventory.explorer.mapHeight":400.0,"inventory.explorer.showMap":true,"inventory.explorer.technical":false,"inventory.explorer.inspector":true,"inventory.livingTree.dimension":"flat","event.showEvidence":false,"inventory.header.details":false,"inventory.explorer.treeNavigatorExpanded":false,"visual.capture.inspectorAccounting":false,"visual.capture.inspectorCleanup":false])
        let store=ViewerStore(configuration:config)
        store.filters.time = .month; store.chartRange = .week
        store.selection=nil; store.showInspector=false
        store.refresh(); store.refreshLive()
        guard await waitFor(40, { store.snapshot != nil }) else { fatalError("History not loaded: \(store.error ?? "unknown")") }
        _ = await waitFor(10) { store.live.state.reading != nil }
        print("DATA events=\(store.visibleEvents.count), readings=\(store.snapshot?.measurements.count ?? 0)"); fflush(stdout)
        func shot<V:View>(_ name:String,_ w:CGFloat=1440,_ h:CGFloat=840,_ dark:Bool=true,_ view:V) async {
            let host=CaptureHost(view,w,h,dark); try? await Task.sleep(for: .seconds(3)); host.capture(out+"/"+name+".png"); host.window.contentView=nil
        }
        // All windows remain hidden; only model state changes, no synthetic pointer or keyboard input.
        if !args.contains("--inventory-only") {
        await shot("m01-monitoring-default-large-dark",1440,840,true,HistoryView(store:store))
        await shot("m02-monitoring-minimum-dark",1000,640,true,HistoryView(store:store))
        await shot("m03-monitoring-minimum-light",1000,640,false,HistoryView(store:store))
        let rich=store.snapshot!.events.first(where:{$0.id=="reading:23"}) ?? store.visibleEvents.first!
        let newest=LatestChange.pick(store.snapshot!.events) ?? rich
        store.selection=rich.id; store.showInspector=true
        await shot("m04-monitoring-selected-event-large-light",1440,840,false,HistoryView(store:store))
        await shot("m05-monitoring-selected-event-minimum-dark",1000,640,true,HistoryView(store:store))
        await shot("m06-explanation-complete-dark",440,1050,true,EventDetailView(event:rich).background(Color(nsColor:.windowBackgroundColor)))
        defaults(["event.showEvidence":true])
        await shot("m07-details-and-evidence-expanded-light",520,2350,false,EventDetailView(event:rich).background(Color(nsColor:.windowBackgroundColor)))
        defaults(["event.showEvidence":false])
        await shot("m08-latest-notable-explanation-light",440,1050,false,EventDetailView(event:newest).background(Color(nsColor:.windowBackgroundColor)))
        store.selection=nil;store.showInspector=false
        await shot("m09-settings-dark",640,780,true,AppearanceSettings(store:store))
        // Summary scrolled to its bottom in the real compact layout to expose its chart.
        let compact=CaptureHost(HistoryView(store:store),1000,640,false); try? await Task.sleep(for: .seconds(2))
        if let scroll=views(NSScrollView.self,in:compact.root).first(where:{ !($0.documentView is NSTableView) && (($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height+10) }),let doc=scroll.documentView {
            scroll.contentView.scroll(to:NSPoint(x:0,y:doc.isFlipped ? max(0,doc.frame.height-scroll.contentView.bounds.height) : 0));scroll.reflectScrolledClipView(scroll.contentView);pump(0.4)
        }
        compact.capture(out+"/m10-monitoring-minimum-summary-scrolled-light.png");compact.window.contentView=nil
        }
        let browser=InventoryBrowserModel(database:db,readiness:store.readiness)
        browser.cleanup.allowsTrash=false
        await browser.load()
        guard let root=browser.directory else { fatalError("No inventory root") }
        browser.explorer.show(root:root,trail:browser.breadcrumbs)
        guard await waitFor(40, {browser.explorer.state.children[root.id] != nil}) else { fatalError("No explorer children") }
        func inv(_ name:String,_ dark:Bool=true,_ w:CGFloat=1440,_ h:CGFloat=840) async { await shot(name,w,h,dark,DiskInventoryView(configuration:config,history:store,model:browser)) }
        await inv("i01-storage-default-atlas-light",false)
        await inv("i02-storage-minimum-atlas-dark",true,1000,640)
        let folders=browser.explorer.state.children[root.id]!.items.filter{$0.kind == .directory}.sorted{($0.allocatedBytes ?? 0)>($1.allocatedBytes ?? 0)}
        if let largest=folders.first {
            browser.explorer.toggle(largest.id)
            _ = await waitFor {browser.explorer.state.children[largest.id] != nil}
            browser.explorer.selection=largest.id
            await inv("i03-expanded-hierarchy-folder-details-light",false)
        }
        defaults(["inventory.explorer.visualization":"tree"])
        browser.explorer.selection=nil
        browser.livingTree.show(root:root,trail:browser.breadcrumbs)
        guard await waitFor(40, {browser.livingTree.model != nil}) else {fatalError("No living tree")}
        await inv("i04-living-tree-overview-dark")
        defaults(["inventory.livingTree.dimension":"depth"])
        browser.livingTree.setDimension(.depth)
        await inv("i05-living-tree-3d-dark")
        if let model=browser.livingTree.model,let key=model.order.filter({model[$0]!.depth == 2 && model[$0]!.node?.kind == .directory}).max(by:{(model[$0]!.bytes ?? 0)<(model[$1]!.bytes ?? 0)}),let node=model[key]!.node {
            let chain=model.ancestry(of:key).dropFirst().dropLast().compactMap{model[$0]?.node}
            browser.explorer.select(node,through:Array(chain))
            defaults(["inventory.explorer.treeNavigatorExpanded":true])
            await inv("i06-living-tree-selected-folder-dark")
            defaults(["inventory.explorer.treeNavigatorExpanded":false])
            defaults(["inventory.livingTree.dimension":"flat"]);browser.livingTree.setDimension(.flat)
            await inv("i07-living-tree-selection-light",false)
        }
        await shot("i08-living-tree-navigation-help-component",460,570,true,LivingTreeView(browser:browser,explorer:browser.explorer,tree:browser.livingTree).visualReviewHelp.background(Color(nsColor:.windowBackgroundColor)))
        defaults(["inventory.explorer.visualization":"atlas"])
        if let largest=folders.first {
            browser.navigate(largest);await browser.load()
            browser.explorer.show(root:browser.directory ?? largest,trail:browser.breadcrumbs)
            _ = await waitFor {browser.explorer.state.children[largest.id] != nil}
            if let next=browser.explorer.state.children[largest.id]?.items.filter({$0.kind == .directory}).max(by:{($0.allocatedBytes ?? 0)<($1.allocatedBytes ?? 0)}) {
                browser.navigate(next);await browser.load();browser.explorer.show(root:browser.directory ?? next,trail:browser.breadcrumbs)
                _ = await waitFor {browser.explorer.state.children[next.id] != nil}
            }
            await inv("i09-atlas-open-home-light",false)
            defaults(["visual.capture.inspectorAccounting":true,"visual.capture.inspectorCleanup":true])
            await inv("i17-storage-inspector-expanded-light",false)
            defaults(["visual.capture.inspectorAccounting":false,"visual.capture.inspectorCleanup":false])
        }
        browser.navigate(root);await browser.load()
        for (mode,name) in [(InventoryBrowserMode.files,"i10-largest-files-dark"),(.directories,"i11-largest-folders-light")] {
            browser.mode=mode;browser.offset=0;await browser.load();browser.selected=browser.items.first?.id
            await inv(name,mode == .files)
        }
        browser.mode = .review;browser.selected=nil
        let reviewHost=CaptureHost(DiskInventoryView(configuration:config,history:store,model:browser),1440,900,true)
        try? await Task.sleep(for: .seconds(2))
        let q=browser.reviewQueue
        _ = await waitFor(180) {!q.loading && q.snapshot != nil}
        print("QUEUE entries=\(q.snapshot?.entries.count ?? 0) rows=\(q.rows.count) error=\(q.error ?? "none")");fflush(stdout)
        reviewHost.capture(out+"/i12-cleanup-review-candidates-dark.png")
        q.status=nil
        try? await Task.sleep(for: .milliseconds(300))
        defaults(["visual.capture.inspectorAccounting":true,"visual.capture.inspectorCleanup":true])
        if let item=q.rows.first ?? q.snapshot?.entries.first {
            q.selection=[item.id];q.reviewSelection(cleanup:browser.cleanup,preferredID:item.id)
            _ = await waitFor(40) {!q.reviewing}
            pump(1);reviewHost.capture(out+"/i13-cleanup-candidate-selected-dark.png")
            await shot("i14-cleanup-item-full-details-light",480,2200,false,InventoryInspectorView(browser:browser,explorer:browser.explorer,reviewSubject:item.node,showsTrash:true,usesQueueEvidence:true))
        }
        // Include the actual eligibility refusals/evidence for another discovered item if available.
        await shot("i15-cleanup-all-assessments-dark",660,620,true,CleanupReviewPlanView(plan:q.plan,done:{}).background(Color(nsColor:.windowBackgroundColor)))
        if let item=q.rows.first(where:{$0.node.path.contains(".venv") || $0.node.path.contains("venv")}) ?? q.rows.first(where:{$0.id != q.selection.first}) {
            q.selection=[item.id];q.reviewSelection(cleanup:browser.cleanup,preferredID:item.id)
            _ = await waitFor(40) {!q.reviewing}
            await shot("i16-cleanup-other-item-details-dark",480,2200,true,InventoryInspectorView(browser:browser,explorer:browser.explorer,reviewSubject:item.node,showsTrash:true,usesQueueEvidence:true))
        }
        reviewHost.window.contentView=nil
        precondition(NSApp.activationPolicy() == .prohibited, "Capture activation must remain prohibited")
        print("COMPLETE activationPolicy=\(NSApp.activationPolicy().rawValue) visibleWindows=\(NSApp.windows.filter{$0.isVisible}.count)");fflush(stdout)
        exit(0)
    }
}
