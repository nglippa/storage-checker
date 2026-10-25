import Foundation

// Bounded synthetic reconciliation scenarios (generated fixtures under /private/tmp only; no
// existing catalog, no full-volume scope). Prints measured JSON for INVENTORY-RECONCILIATION-STEADY-STATE.md.
@main enum ReconciliationSteadyStateVerification {
    static func main() {
        do {
            let directories = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 12_000
            let report = try reconciliationScenarios(directories: directories)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
