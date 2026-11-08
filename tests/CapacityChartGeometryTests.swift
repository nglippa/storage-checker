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
        livingTreeScrollRoutingChecks(check)
        print("\(checks-failures) of \(checks) hosted chart geometry and scroll routing checks passed")
        if failures > 0 { exit(1) }
    }
}
