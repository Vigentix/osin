import Foundation
import OsinCore

extension ScanCoordinator {
    /// What a scheduled cleanup may touch: safe, regenerable groups only. Never the Trash or simulators
    /// (they cannot be undone), never Downloads (it would prompt for access with nobody watching).
    static func choreRules() -> [CleanupRule] {
        ((try? CleanupRule.bundled()) ?? []).filter { rule in
            rule.tier == .safe && (try? rule.validate()) != nil && !rule.paths.contains { $0.hasPrefix("~/Downloads") }
        }
    }

    /// Scans and cleans the chosen rules in the background, without touching the Smart Scan screen.
    /// `stillAllowed` is checked again before each item is cleaned (the user may have come back,
    /// unplugged the Mac or turned chores off while it scanned); cleaning stops as soon as it fails.
    /// Returns `nil` when nothing ran (Osin busy, nothing chosen, or not allowed any more).
    func runChore(ruleIDs: Set<String>, at date: Date, stillAllowed: () -> Bool) async -> ChoreRun? {
        guard !isBusy, !isScanningInBackground, let cleaner else { return nil }
        let rules = Self.choreRules().filter { ruleIDs.contains($0.id) }
        guard !rules.isEmpty else { return nil }
        isRunningChore = true
        defer { isRunningChore = false }
        guard let results = try? await Scanner().scan(rules), stillAllowed() else { return nil }
        var outcome = CleanupOutcome()
        // What Smart Scan should show afterwards: the fresh scan, minus what was removed.
        var remaining = results
        var stopped = false
        for (index, result) in results.enumerated() where !result.items.isEmpty {
            var left: [ScanItem] = []
            // One item at a time, re-checked in between, so cleaning stops as soon as the user comes back.
            for item in result.items {
                if stopped || !stillAllowed() {
                    stopped = true
                    left.append(item)
                    continue
                }
                let part = await cleaner.clean([CleanupSelection(rule: result.rule, items: [item])])
                onFreed?(part.freedBytes)
                outcome.freedBytes += part.freedBytes
                outcome.trashedBytes += part.trashedBytes
                outcome.failures += part.failures
                if !part.failures.isEmpty {
                    left.append(item)
                }
            }
            remaining[index] = RuleScanResult(rule: result.rule, items: left, needsAccess: result.needsAccess)
        }
        replaceGroups(with: remaining)
        if outcome.freedBytes + outcome.trashedBytes > 0 || !outcome.failures.isEmpty {
            historyRevision += 1
            onCleaned?()
        }
        return ChoreRun(date: date, freedBytes: outcome.freedBytes, trashedBytes: outcome.trashedBytes, failures: outcome.failures.count)
    }
}
