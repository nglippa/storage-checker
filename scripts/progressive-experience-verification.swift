import Foundation
import Darwin

// Bounded generated fixture only; no existing catalog or unrestricted scope argument.
@main enum ProgressiveExperienceVerification {
    static func main() async {
        do {
            var checks = 0
            let result = try await progressiveFixture({ condition, label in
                try required(condition, label); checks += 1
            }, keep: true)
            var output = result
            output["checks_passed"] = checks
            output["scope"] = "Generated 32 background folders, 1200-entry focus directory, deep hierarchy, hard links, permissions and changes; no full-volume scan"
            print(json(output))
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
