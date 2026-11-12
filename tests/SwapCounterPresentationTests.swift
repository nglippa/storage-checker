import Foundation

@main struct SwapCounterPresentationTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw HistoryError.invalid("TEST FAILED: \(message)") }
            checks += 1; print("PASS \(message)")
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000), end = start.addingTimeInterval(1800)
        let boot = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        func observation(_ time: Date, allocated: Int64?, used: Int64?, bootID: String = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", uptime: Double, duration: Double = 1, container: String = "fixture") -> StorageObservation {
            var value = StorageObservation(container: container, observedAt: time.timeIntervalSince1970, finishedAt: time.timeIntervalSince1970 + duration, inventories: [], capacities: [], swapAllocatedBytes: allocated, swapUsedBytes: used, vmCounters: nil, detail: "SYNTHETIC SWAP COUNTER FIXTURE")
            value.bootSession = bootID; value.uptime = uptime; return value
        }
        func event(vmBefore: Int64 = 2*decimalGB, vmAfter: Int64 = 5*decimalGB, allocatedBefore: Int64? = 2*decimalGB, allocatedAfter: Int64? = 5*decimalGB, usedBefore: Int64? = decimalGB/2, usedAfter: Int64? = 3*decimalGB/2, interval: TimeInterval = 1800, capacityChange: Int64 = 0) -> StorageEvent {
            let eventEnd = start.addingTimeInterval(interval)
            let a = Measurement(id: 1, timestamp: start, container: "fixture", free: 50*decimalGB, used: 195*decimalGB, volumes: [.init(id: "vm", name: "VM", bytes: vmBefore, roles: ["VM"])])
            let b = Measurement(id: 2, timestamp: eventEnd, container: "fixture", free: a.free - (vmAfter-vmBefore), used: a.used + (vmAfter-vmBefore) + capacityChange, volumes: [.init(id: "vm", name: "VM", bytes: vmAfter, roles: ["VM"])])
            var result = StorageEvent(id: "reading:2", timestamp: eventEnd, category: vmAfter > vmBefore ? "Storage loss" : "Storage recovery", delta: b.free-a.free, previousFree: a.free, currentFree: b.free, previousTime: start, severity: .normal, measurement: b, previousMeasurement: a, alerts: [], diagnostics: [], comparisons: [], source: "synthetic", searchText: "")
            result.previousObservation = observation(start, allocated: allocatedBefore, used: usedBefore, uptime: 1000)
            result.observation = observation(eventEnd, allocated: allocatedAfter, used: usedAfter, uptime: 1000 + interval)
            return result
        }
        func plain(_ e: StorageEvent) -> EventPlainSummary { EventPlainSummary.make(e, CauseAnalyzer.analyze(e)) }
        let growth = event(), growthPlain = plain(growth)
        try expect(growthPlain.explanation?.contains("Swap allocation: 2.00 GB → 5.00 GB (+3.00 GB)") == true, "VM explanation uses the recorded allocated counter pair")
        try expect(growthPlain.explanation?.contains("Swap used: 0.50 GB → 1.50 GB (+1.00 GB)") == true, "VM explanation shows used bytes separately from allocation")
        try expect(growthPlain.explanation?.contains("closely matched") == true && growthPlain.explanation?.contains("Separate swap counters are needed") == false, "matching counters replace generic missing-counter advice")
        try expect(growthPlain.certainty == .measured && growthPlain.certaintyText.contains("Which app caused it was not recorded"), "swap evidence does not promote application attribution or reconciliation certainty")
        let signals = StorageIntelligence.signals(growth)
        try expect(signals.first { $0.id == "swap" }?.detail.contains("Swap used: 0.50 GB → 1.50 GB (+1.00 GB)") == true, "measured system signal includes the usage pair")
        try expect(signals.contains { $0.id == "vm-correlation" && $0.confidence == .strongCorrelation }, "matching allocation is a correlation, not another additive cause")
        try expect(CauseAnalyzer.analyze(growth).causes.first?.support.contains { $0.contains("Swap allocation: 2.00 GB → 5.00 GB") } == true, "copied likely-cause support includes per-reading swap evidence")
        let reduction = event(vmBefore: 5*decimalGB, vmAfter: 2*decimalGB, allocatedBefore: 5*decimalGB, allocatedAfter: 2*decimalGB, usedBefore: 2*decimalGB, usedAfter: decimalGB)
        try expect(plain(reduction).explanation?.contains("Swap allocation: 5.00 GB → 2.00 GB (−3.00 GB)") == true, "recovery explains a measured reduction with signed swap delta")
        let unchanged = event(allocatedAfter: 2*decimalGB)
        try expect(plain(unchanged).explanation?.contains("Swap allocation: 2.00 GB → 2.00 GB (0 B)") == true && plain(unchanged).explanation?.contains("did not change") == true, "usage can rise within unchanged allocated swap")
        for mismatched in [unchanged, event(allocatedAfter: decimalGB), event(allocatedAfter: 8*decimalGB)] {
            try expect(!StorageIntelligence.signals(mismatched).contains { $0.id == "vm-correlation" } && plain(mismatched).explanation?.contains("closely matched") != true, "opposite, unchanged or mismatched counters do not imply VM correlation")
        }
        try expect(unchanged.hasSwapChange, "Swap Changes includes usage changes within unchanged allocated swap")
        var swapFilter = EventFilters(); swapFilter.type = .swap
        try expect(swapFilter.apply([unchanged], now: end).count == 1, "Swap Changes filter includes per-reading used-byte changes")
        try expect(!event(allocatedBefore: nil, usedBefore: nil).hasSwapChange, "one-sided counters do not imply a swap change")
        for e in [event(interval: 5000), event(capacityChange: decimalGB)] {
            try expect(plain(e).explanation?.contains("Swap allocation:") != true, "long gaps and capacity changes prevent swap pairing")
        }
        let partial = event(usedBefore: nil)
        try expect(plain(partial).explanation?.contains("Swap allocation: 2.00 GB → 5.00 GB") == true && plain(partial).explanation?.contains("Swap used:") == false, "missing usage is not fabricated while allocation remains usable")
        let usageOnly = event(allocatedBefore: nil)
        try expect(plain(usageOnly).explanation?.contains("Swap allocation:") == false && plain(usageOnly).explanation?.contains("Swap used: 0.50 GB → 1.50 GB") == true, "usage can be reported when allocation pairing is unavailable")
        var legacy = growth; legacy.observation = nil; legacy.previousObservation = nil
        try expect(plain(legacy).explanation?.contains("not recorded at both ends") == true && plain(legacy).explanation?.contains("Swap allocation:") == false, "old events explain missing counters without inventing history")
        let invalid: [StorageObservation] = [
            observation(end, allocated: 5*decimalGB, used: decimalGB, bootID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", uptime: 2800),
            observation(end, allocated: 5*decimalGB, used: decimalGB, bootID: boot, uptime: 900),
            observation(end, allocated: 5*decimalGB, used: decimalGB, bootID: boot, uptime: 2800, duration: 121),
            observation(end.addingTimeInterval(30), allocated: 5*decimalGB, used: decimalGB, uptime: 2800),
            observation(end, allocated: 5*decimalGB, used: decimalGB, uptime: 2800, container: "other")
        ]
        for bad in invalid {
            var e = growth; e.observation = bad
            try expect(plain(e).explanation?.contains("Swap allocation:") != true && !StorageIntelligence.signals(e).contains { $0.id == "vm-correlation" }, "invalid time/session/scope suppresses paired counter attribution")
            try expect(!e.hasSwapChange, "invalid time/session/scope does not enter the per-reading swap filter")
        }
        var boundary = growth; boundary.previousObservation = nil
        try expect(plain(boundary).explanation?.contains("Swap allocation:") != true, "session boundary has no fabricated comparison")
        let raw = StorageIntelligence.inventoryText(growth) ?? ""
        try expect(raw.contains("Swap counters (sysctl vm.swapusage)") && raw.contains("5,000,000,000 bytes") && raw.contains("1,500,000,000 bytes"), "technical sources preserve exact current swap counters")
        print("\(checks) swap-counter presentation checks passed")
    }
}
