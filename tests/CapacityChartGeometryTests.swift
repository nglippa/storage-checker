import AppKit
import SwiftUI

/// Hosts the real Monitoring `CapacityChart` offscreen (never ordered front, `.prohibited` activation policy, so it cannot
/// take focus) and checks the hover regression: hovering a reading must not change the plot frame or move any point, and
/// the pointer that caused the hover must still hit the same reading in the hovered layout. A layout that moves the point
/// away from the pointer is the enter/exit loop that made the chart truncate, expand and flicker.
@main struct CapacityChartGeometryTests {
    struct Layout { var plot: CGRect = .zero; var positions: [Date:CGPoint] = [:] }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let now = Date()
        var readings: [Measurement] = [], events: [StorageEvent] = []
        // 47 half-hourly readings over the last day. The free-space walk reaches the top of the y-domain, the floor near the
        // thresholds and both chart edges, and has ≥ 1 GB jumps so event points are drawn.
        let walk: [Double] = (0..<47).map { i in
            switch i { case 0..<8: return 62+Double(i)*0.4; case 8..<14: return 48-Double(i-8)*0.3; case 14..<20: return 18+Double(i-14)*0.2
            case 20..<28: return 71+Double(i-20)*0.25; case 28..<36: return 90-Double(i-28)*0.1; default: return 36+Double(i-36)*0.3 }
        }
        for (i,gb) in walk.enumerated() {
            let free = Int64(gb*Double(decimalGB))
            let m = Measurement(id:Int64(i+1),timestamp:now.addingTimeInterval(Double(i-46)*1800-60),container:"A",free:free,used:245*decimalGB-free,volumes:[])
            if let previous = readings.last {
                let delta = m.free-previous.free
                events.append(StorageEvent(id:"reading:\(m.id)",timestamp:m.timestamp,category:delta < 0 ? "Storage decrease" : "Storage increase",delta:delta,previousFree:previous.free,currentFree:m.free,previousTime:previous.timestamp,severity:.normal,measurement:m,previousMeasurement:previous,alerts:[],diagnostics:[],comparisons:[],source:"fixture",searchText:""))
            }
            readings.append(m)
        }
        let selected = events.first { abs($0.delta ?? 0) >= decimalGB && $0.measurement!.free > 85*decimalGB }!.id
        // Optional: CHART_GEOMETRY_SNAPSHOTS=<folder> writes a PNG of every hosted layout for visual evidence.
        let snapshotFolder = ProcessInfo.processInfo.environment["CHART_GEOMETRY_SNAPSHOTS"].map { URL(fileURLWithPath:$0,isDirectory:true) }
        if let snapshotFolder { try? FileManager.default.createDirectory(at:snapshotFolder,withIntermediateDirectories:true) }

        func layout(width: CGFloat,compact: Bool,dark: Bool,hover: Date?,selection: String?) -> Layout {
            var result = Layout()
            let chart = CapacityChart(readings:readings,events:events,selectedEventID:selection,range:.constant(.day),compact:compact,selectEvent:{ _ in },inspectHoverAt:hover) { plot,positions in result = Layout(plot:plot,positions:positions) }
            let window = NSWindow(contentRect:CGRect(x:-10000,y:-10000,width:width,height:400),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView:chart.frame(width:width).fixedSize(horizontal:false,vertical:true))
            for _ in 0..<6 { window.contentView!.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
            if let snapshotFolder, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                let name = "w\(Int(width))-\(compact ? "compact" : "regular")-\(dark ? "dark" : "light")-hover\(hover.flatMap { h in readings.firstIndex { $0.timestamp == h } }.map { String($0+1) } ?? "none")\(selection == nil ? "" : "-selected").png"
                try? rep.representation(using:.png,properties:[:])?.write(to:snapshotFolder.appendingPathComponent(name))
            }
            window.contentView = nil
            return result
        }

        var failures = 0, checks = 0
        func check(_ ok: Bool,_ message: String) { checks += 1; if ok { print("PASS \(message)") } else { failures += 1; print("FAIL \(message)") } }
        func moved(_ a: CGRect,_ b: CGRect) -> Bool { abs(a.minX-b.minX) > 0.5 || abs(a.minY-b.minY) > 0.5 || abs(a.width-b.width) > 0.5 || abs(a.height-b.height) > 0.5 }

        for (width,compact,dark) in [(CGFloat(640),true,false),(640,false,true),(1100,false,false),(1100,true,true)] {
            for selection in [nil,selected] as [String?] {
                let base = layout(width:width,compact:compact,dark:dark,hover:nil,selection:selection)
                let label = "\(Int(width))pt \(compact ? "compact" : "regular") \(dark ? "dark" : "light")\(selection == nil ? "" : " with selected event")"
                guard base.plot.width > 0, base.positions.count == readings.count else { check(false,"\(label): chart laid out with every reading (\(base.positions.count) of \(readings.count))"); continue }
                var resized: [String] = [], lost: [String] = []
                for reading in readings {
                    let hovered = layout(width:width,compact:compact,dark:dark,hover:reading.timestamp,selection:selection)
                    let tag = "#\(reading.id) (\(Double(reading.free)/1e9) GB)"
                    if moved(base.plot,hovered.plot) { resized.append("\(tag) plot \(base.plot.integral) → \(hovered.plot.integral)") }
                    // The pointer sits where the reading was drawn before hovering. After the hover's own layout, the nearest
                    // reading within the 14 pt hit radius must still be the same one, or the hover drops and the cycle repeats.
                    let pointer = base.positions[reading.timestamp]!
                    let nearest = hovered.positions.min { hypot($0.value.x-pointer.x,$0.value.y-pointer.y) < hypot($1.value.x-pointer.x,$1.value.y-pointer.y) }
                    if nearest.map({ $0.key != reading.timestamp || hypot($0.value.x-pointer.x,$0.value.y-pointer.y) > 14 }) ?? true { lost.append(tag) }
                }
                for line in resized.prefix(4) { print("  resized while hovering \(line)") }
                check(resized.isEmpty,"\(label): hovering any of \(readings.count) readings leaves the plot frame unchanged (\(resized.count) changed it)")
                check(lost.isEmpty,"\(label): the hovered reading stays under the pointer after the hover layout (\(lost.count) would drop and re-enter: \(lost.prefix(5).joined(separator:", ")))")
            }
        }
        // Functional hover: real NSEvent pointer moves through the chart's own tracking layer (delivered to it directly:
        // an unshown window gets no window-server tracking events). The geometry checks above set the hover through a
        // seam and so could not notice a callout that never appears.
        for (width,compact,dark) in [(CGFloat(640),true,false),(1100,false,true),(1000,false,false)] {
            let label = "\(Int(width))pt \(compact ? "compact" : "regular") \(dark ? "dark" : "light")"
            var plot = CGRect.zero, positions: [Date:CGPoint] = [:], hoveredAt: Date??, callout: CGRect?
            let chart = CapacityChart(readings:readings,events:events,selectedEventID:nil,range:.constant(.day),compact:compact,selectEvent:{ _ in },
                                      onPlotLayout:{ plot = $0; positions = $1 },
                                      onHoverLayout:{ date,frame in hoveredAt = .some(date); if date == nil { callout = nil } else if let frame { callout = frame } })
            let window = NSWindow(contentRect:CGRect(x:-10000,y:-10000,width:width,height:400),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView:chart.frame(width:width).fixedSize(horizontal:false,vertical:true))
            func pump() { for _ in 0..<4 { window.contentView!.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.02)) } }
            pump()
            func find(_ view: NSView) -> ChartPointerView? { (view as? ChartPointerView) ?? view.subviews.lazy.compactMap(find).first }
            guard let pointer = find(window.contentView!), plot.width > 0 else { check(false,"\(label): the chart's pointer layer is present"); continue }
            let basePlot = plot
            func move(_ p: CGPoint?) {
                let location = pointer.convert(p ?? CGPoint(x:-50,y:-50),to:nil)
                let event = NSEvent.mouseEvent(with:.mouseMoved,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
                if p == nil, let exit = NSEvent.enterExitEvent(with:.mouseExited,location:location,modifierFlags:[],timestamp:event.timestamp,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil) { pointer.mouseExited(with:exit) }
                else { pointer.mouseMoved(with:event) }
                pump()
            }
            var missed: [String] = [], outside: [String] = [], unstable: [String] = [], resized = 0
            let bounds = pointer.bounds.insetBy(dx:-0.5,dy:-0.5)
            for (i,reading) in readings.enumerated() {
                guard let p = positions[reading.timestamp] else { missed.append("#\(i+1) not drawn"); continue }
                callout = nil
                move(CGPoint(x:p.x+3,y:p.y-2))
                guard hoveredAt == .some(reading.timestamp), let shown = callout else { missed.append("#\(i+1)"); continue }
                if !bounds.contains(shown) { outside.append("#\(i+1) \(shown.integral)") }
                if moved(basePlot,plot) { resized += 1 }
                move(CGPoint(x:p.x+4,y:p.y-1))   // still on the same reading: nothing changes
                if hoveredAt != .some(reading.timestamp) || callout.map({ moved($0,shown) }) != false { unstable.append("#\(i+1)") }
            }
            check(missed.isEmpty,"\(label): a pointer on each of \(readings.count) readings shows that reading's callout, including the last third (\(missed.count) missed: \(missed.prefix(6).joined(separator:", ")))")
            check(outside.isEmpty,"\(label): every hover callout is drawn inside the chart, near the plot edges too (\(outside.count) outside: \(outside.prefix(3).joined(separator:", ")))")
            check(unstable.isEmpty && resized == 0,"\(label): the callout holds still while the pointer stays on its reading, and the plot never resizes (\(unstable.count) unstable, \(resized) resized)")
            // Empty plot (near the top, midway between two readings) and leaving the chart: no callout.
            let sorted = positions.values.sorted { $0.x < $1.x }
            let mid = sorted.count > 24 ? CGPoint(x:(sorted[22].x+sorted[23].x)/2,y:basePlot.minY+2) : CGPoint(x:basePlot.midX,y:basePlot.minY+2)
            let farFromAll = positions.values.allSatisfy { hypot($0.x-mid.x,$0.y-mid.y) > CapacityChartHover.radius }
            move(mid)
            let emptyClear = hoveredAt == .some(nil) && callout == nil
            if let first = sorted.first { move(first) }
            move(nil)
            check(farFromAll && emptyClear && hoveredAt == .some(nil) && callout == nil,"\(label): no callout over empty plot, and leaving the chart dismisses it (empty plot clear \(emptyClear))")
            window.contentView = nil
        }
        // The callout says when, how much is available, and the change from the previous joined reading.
        let described = CapacityChartHover.describe(date:readings[30].timestamp,free:readings[30].free,previousFree:readings[29].free)
        let firstDescribed = CapacityChartHover.describe(date:readings[0].timestamp,free:readings[0].free,previousFree:nil)
        check(described.contains("\(capacity(readings[30].free)) free") && described.contains(signedChange(readings[30].free-readings[29].free)) && !firstDescribed.contains("since"),
              "the hover callout gives time, available space and the change since the previous reading (\(described))")
        livingTreeScrollRoutingChecks(check)
        structuredExplorerStateChecks(check)
        print("\(checks-failures) of \(checks) hosted chart geometry and scroll routing checks passed")
        if failures > 0 { exit(1) }
    }
}
