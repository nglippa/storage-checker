import AppKit
import ApplicationServices
import Foundation

// Drives real native controls in an already running, explicitly QA-labelled
// viewer. Never launches against or edits the production monitoring database.
@main struct GUIAXTests {
    static func main() async throws {
        setbuf(stdout,nil)
        guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]) else { fatalError("usage: GUIAXTests PID /absolute/populated.sqlite3 [--dates-only]") }
        guard AXIsProcessTrusted() else { throw HistoryError.invalid("Native AX test process is not trusted. Use the permitted mac-use host for interaction; no permission changes attempted.") }
        let app = AXUIElementCreateApplication(pid)
        func value(_ element: AXUIElement,_ attribute: String) -> CFTypeRef? { var output: CFTypeRef?; guard AXUIElementCopyAttributeValue(element,attribute as CFString,&output) == .success else { return nil }; return output }
        func string(_ element: AXUIElement,_ attribute: String) -> String { value(element,attribute) as? String ?? "" }
        func children(_ element: AXUIElement) -> [AXUIElement] { value(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func find(_ predicate: (AXUIElement)->Bool) -> AXUIElement? {
            var queue = [app], visited = 0
            while !queue.isEmpty && visited < 10000 { let node = queue.removeFirst(); visited += 1; if predicate(node) { return node }; queue += children(node) }
            return nil
        }
        func identifier(_ id: String) -> AXUIElement? { find { string($0,kAXIdentifierAttribute)==id } }
        func pause(_ seconds: Double = 0.55) { Thread.sleep(forTimeInterval:seconds) }
        func press(_ element: AXUIElement) throws { guard AXUIElementPerformAction(element,kAXPressAction as CFString) == .success else { throw HistoryError.invalid("Could not press \(string(element,kAXTitleAttribute))") }; pause() }
        func popup(_ id: String,_ title: String) throws {
            guard let element = identifier(id) else { throw HistoryError.invalid("Missing native popup \(id); close event inspector and use standard window width") }
            try press(element)
            guard let item = find({ string($0,kAXRoleAttribute)==kAXMenuItemRole && string($0,kAXTitleAttribute)==title }) else { throw HistoryError.invalid("Native menu item not found: \(title)") }
            try press(item)
        }
        func clear() throws { if let element = identifier("filter.clear"), (value(element,kAXEnabledAttribute) as? Bool) == true { try press(element) }; pause() }
        func setText(_ id: String,_ text: String) throws {
            guard let field = identifier(id), AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw HistoryError.invalid("Unable to focus text control \(id)") }
            // AXValue changes only the editor on this SDK. Real key events to
            // the QA process trigger SwiftUI's normal text-editing binding.
            func key(_ code: CGKeyCode,_ flags: CGEventFlags = []) {
                for down in [true,false] { let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down); event?.flags = flags; event?.postToPid(pid) }
            }
            key(0,.maskCommand); pause(0.1)
            let utf16 = Array(text.utf16)
            for down in [true,false] { let event = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down); utf16.withUnsafeBufferPointer { buffer in event?.keyboardSetUnicodeString(stringLength:buffer.count,unicodeString:buffer.baseAddress) }; event?.postToPid(pid) }
            pause(); key(36); pause()
        }
        func resultCount() throws -> Int {
            guard let count = identifier("history.resultCount") else { throw HistoryError.invalid("Missing visible result-count element") }
            let text = string(count,kAXValueAttribute).isEmpty ? string(count,kAXTitleAttribute) : string(count,kAXValueAttribute)
            guard let number = Int(text.split(separator:" ").first ?? "") else { throw HistoryError.invalid("Unreadable result count: \(text)") }; return number
        }
        func textValues(_ element: AXUIElement) -> [String] {
            let role = string(element,kAXRoleAttribute)
            let own = role == kAXStaticTextRole || role == kAXTextAreaRole ? [string(element,kAXValueAttribute)] : (role == "AXHeading" ? [string(element,kAXTitleAttribute)+string(element,kAXDescriptionAttribute)+string(element,kAXValueAttribute)] : [])
            return own + children(element).flatMap(textValues)
        }
        func tableRows() -> [AXUIElement] {
            guard let table = identifier("history.table") else { return [] }
            return value(table,kAXRowsAttribute) as? [AXUIElement] ?? children(table).filter { string($0,kAXRoleAttribute) == kAXRowRole }
        }
        var tests = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw HistoryError.invalid("Native UI assertion failed: \(name)") }; tests += 1; print("PASS native UI \(name)") }
        guard find({ string($0,kAXRoleAttribute)==kAXWindowRole && string($0,kAXTitleAttribute).contains("QA:") }) != nil else { throw HistoryError.invalid("Refusing to drive a window that is not explicitly labelled QA") }
        let snapshot = try await HistoryReader(path:CommandLine.arguments[2]).load()
        func expect(_ filters: EventFilters,_ name: String) throws {
            let expected = filters.apply(snapshot.events).count
            for _ in 0..<20 { if (try? resultCount()) == expected { break }; pause(0.1) }
            let actual = try resultCount()
            try check(actual == expected,"\(name) (\(actual) / expected \(expected))")
        }
        func verifyDates() throws {
            var filters = EventFilters(); filters.time = .custom
            filters.start = minuteBoundary(Date().addingTimeInterval(-1800)); filters.end = minuteBoundary(Date())
            func setDate(_ id: String,_ date: Date) throws {
                guard let field = identifier(id), AXUIElementSetAttributeValue(field,kAXValueAttribute as CFString,date as NSDate) == .success else { throw HistoryError.invalid("Unable to edit native date control \(id)") }; pause()
            }
            try setDate("filter.start",filters.start); try setDate("filter.end",filters.end)
            try expect(filters,"edited custom date range changes rows")
            try setDate("filter.start",filters.end.addingTimeInterval(60)); pause()
            try check(identifier("filters.validation") != nil && resultCount()==0,"reversed edited custom dates visibly rejected")
        }
        // Inspector hierarchy and native disclosure behaviour. No popup menus are opened.
        func verifyInspector(_ detailText: String) throws {
            for heading in ["Likely causes","Storage breakdown","Supporting evidence","Technical details"] { try check(detailText.contains(heading),"inspector shows \(heading)") }
            if let first = ["Likely causes","Storage breakdown","Supporting evidence","Technical details"].map({ detailText.range(of:$0)!.lowerBound }) as [String.Index]? { try check(first == first.sorted(),"Likely causes is the first section, in reading order") }
            try check(!detailText.contains("Previous reading #"),"technical details collapsed by default")
            // Events without a reading have no APFS section; use the first section present.
            guard let section = find({ string($0,kAXIdentifierAttribute).hasPrefix("event.technical.") }) else { try check(false,"a technical disclosure is present"); return }
            let name = string(section,kAXIdentifierAttribute)
            let before = (identifier("event.details").map(textValues) ?? []).joined(separator:"\n").count
            try press(section)
            let expanded = (identifier("event.details").map(textValues) ?? []).joined(separator:"\n")
            try check(expanded.count > before,"\(name) disclosure expands natively")
            if name == "event.technical.APFS" { try check(expanded.contains("Container "),"APFS disclosure shows container provenance") }
            try press(section)
        }
        // Overview: live status and the recorded line expose current, complete labels.
        func label(_ id: String) -> String { identifier(id).map { string($0,kAXDescriptionAttribute) + string($0,kAXValueAttribute) + string($0,kAXTitleAttribute) } ?? "" }
        if CommandLine.arguments.contains("--overview-only") {
            try check(label("overview.recorded").hasPrefix("Last recorded reading"),"recorded reading line has a full accessible label")
            if let folders = snapshot.folderMonitoring { try check(label("overview.folderMonitoring") == "Folder monitoring: \(folders.summary)","folder monitoring status has an accessible label (\(label("overview.folderMonitoring")))") }
            let before = label("overview.liveStatus")
            try check(before.hasPrefix("Live, updated") || before.hasPrefix("Stale"),"live status has an accessible label (\(before))")
            pause(1.2)
            guard let bar = value(app,kAXMenuBarAttribute) else { throw HistoryError.invalid("No menu bar") }
            var queue = [bar as! AXUIElement], refresh: AXUIElement?
            while !queue.isEmpty && refresh == nil { let n = queue.removeFirst(); if string(n,kAXTitleAttribute) == "Refresh" && string(n,kAXRoleAttribute) == kAXMenuItemRole { refresh = n }; queue += children(n) }
            guard let refresh else { throw HistoryError.invalid("No Refresh menu item") }
            try press(refresh); pause(1.5)
            try check(label("overview.liveStatus") != before,"Refresh updates the accessible live status (\(label("overview.liveStatus")))")
            print("\(tests) native overview checks passed")
            return
        }
        if CommandLine.arguments.contains("--inspector-only") {
            guard let table = identifier("history.table") else { throw HistoryError.invalid("No table") }
            let rows = tableRows()
            try check(!rows.isEmpty,"native table exposes rows")
            for (index,row) in rows.prefix(6).enumerated() {
                _ = AXUIElementSetAttributeValue(table,kAXSelectedRowsAttribute as CFString,[row] as CFArray); pause(1)
                let text = (identifier("event.details").map(textValues) ?? []).joined(separator:"\n")
                try check(identifier("event.details") != nil,"row \(index) opens inspector")
                try verifyInspector(text)
            }
            print("\(tests) native inspector checks passed")
            return
        }
        if CommandLine.arguments.contains("--dates-only") {
            try clear(); try popup("filter.time",EventTimeFilter.custom.rawValue); pause(1)
            try verifyDates(); try clear()
            print("\(tests) native custom-date checks passed")
            return
        }
        if CommandLine.arguments.contains("--chart-only") {
            for range in EventTimeFilter.allCases where range != .custom {
                try popup("chart.range",range.rawValue)
                let count = snapshot.measurements.filter { $0.timestamp >= Date().addingTimeInterval(-range.seconds!) }.count
                let label = "\(count) points"
                try check(find({ string($0,kAXValueAttribute)==label }) != nil,"chart \(range.rawValue) uses \(count) real points")
            }
            try popup("chart.range",EventTimeFilter.day.rawValue)
            print("\(tests) native chart range checks passed")
            return
        }
        try clear(); try expect(EventFilters(),"Clear Filters restores defaults")
        for type in EventTypeFilter.allCases {
            try clear(); try popup("filter.type",type.rawValue)
            var filters = EventFilters(); filters.type = type
            try expect(filters,"type \(type.rawValue)")
        }
        for time in EventTimeFilter.allCases where time != .custom {
            try clear(); try popup("filter.time",time.rawValue)
            var filters = EventFilters(); filters.time = time
            try expect(filters,"time \(time.rawValue)")
        }
        try clear(); try popup("filter.time",EventTimeFilter.custom.rawValue)
        pause(1)
        try check(identifier("filter.start") != nil && identifier("filter.end") != nil,"Custom Date Range exposes native date inputs")
        try verifyDates()
        for size in EventSizeFilter.allCases where size != .custom {
            try clear(); try popup("filter.size",size.rawValue)
            var filters = EventFilters(); filters.size = size
            try expect(filters,"size \(size.rawValue)")
        }
        try clear(); try popup("filter.size",EventSizeFilter.custom.rawValue)
        try setText("filter.threshold","3")
        var custom = EventFilters(); custom.size = .custom; custom.customThreshold = "3"
        try expect(custom,"Custom Threshold 3 GB")
        try setText("filter.threshold","invalid")
        try check(identifier("filters.validation") != nil && resultCount()==0,"invalid custom size is visibly rejected")
        for severity in [-1] + EventSeverity.allCases.map(\.rawValue) {
            try clear(); try popup("filter.severity",severity == -1 ? "All Severities" : EventSeverity(rawValue:severity)!.label)
            var filters = EventFilters(); filters.severity = severity
            try expect(filters,"severity \(severity)")
        }
        try clear(); try setText("filter.search","code_sign_clone")
        var search = EventFilters(); search.search = "code_sign_clone"
        try expect(search,"search recorded diagnostic evidence")
        try clear(); try popup("filter.type",EventTypeFilter.loss.rawValue); try popup("filter.size",EventSizeFilter.gb1.rawValue)
        var combined = EventFilters(); combined.type = .loss; combined.size = .gb1
        try expect(combined,"Loss >1 GB in last24h")
        try popup("filter.severity",EventSeverity.critical.label); combined.severity = EventSeverity.critical.rawValue
        try expect(combined,"type + time + size + severity")
        try setText("filter.search","fixture-critical"); combined.search = "fixture-critical"
        try expect(combined,"type + time + size + severity + search")
        for sort in EventSort.allCases {
            try clear(); try popup("filter.sort",sort.rawValue)
            var filters = EventFilters(); filters.sort = sort
            try expect(filters,"sort \(sort.rawValue) keeps rows")
            let expected = filters.apply(snapshot.events).map { $0.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()) }
            var actual = tableRows().compactMap { textValues($0).first }
            for _ in 0..<20 where actual != expected { pause(0.1); actual = tableRows().compactMap { textValues($0).first } }
            try check(actual == expected,"sort \(sort.rawValue) actual row order")
        }
        try clear()
        if let table = identifier("history.table"), let row = tableRows().first {
            let selected = AXUIElementSetAttributeValue(table,kAXSelectedRowsAttribute as CFString,[row] as CFArray)
            pause(1)
            try check(selected == .success && identifier("event.details") != nil,"row selection opens native event inspector")
            let detail = identifier("event.details").map(textValues) ?? []
            let detailText = detail.joined(separator:"\n")
            try verifyInspector(detailText)
            if let button = identifier("history.inspector") { try press(button) }
        } else { try check(false,"native table exposes rows") }
        try clear()
        print("\(tests) real-control checks passed. Fixture path: \(CommandLine.arguments[2])")
        print("Native date editing and validation exercised; the pure model suite covers exact inclusive boundaries.")
    }
}
