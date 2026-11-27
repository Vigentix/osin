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
    /// `stillAllowed(ruleID)` is checked again right before each item is removed (the user may have
    /// come back, unplugged the Mac, turned chores off, changed the schedule or unticked the rule);
    /// cleaning stops as soon as it fails.
    /// Returns `nil` when nothing ran (Osin busy, nothing chosen, or not allowed any more).
    func runChore(ruleIDs: Set<String>, at date: Date, stillAllowed: @escaping @Sendable (String) -> Bool) async -> ChoreRun? {
        guard !isBusy, !isScanningInBackground, let cleaner else { return nil }
        let rules = Self.choreRules().filter { ruleIDs.contains($0.id) }
        guard !rules.isEmpty else { return nil }
        isRunningChore = true
        defer { isRunningChore = false }
        guard let results = try? await Scanner().scan(rules), rules.contains(where: { stillAllowed($0.id) }) else { return nil }
        var outcome = CleanupOutcome()
        // What Smart Scan should show afterwards: the fresh scan, minus what was removed.
        var remaining = results
        var stopped = false
        for (index, result) in results.enumerated() where !result.items.isEmpty {
            var left: [ScanItem] = []
            // One item at a time, re-checked in between, so cleaning stops as soon as the user comes back.
            for item in result.items {
                let ruleID = result.rule.id
                if stopped || !stillAllowed(ruleID) {
                    stopped = true
                    left.append(item)
                    continue
                }
                // Asked again inside the cleaner, right before removal (checking a large folder takes time).
                let part = await cleaner.clean([CleanupSelection(rule: result.rule, items: [item])]) { @Sendable in stillAllowed(ruleID) }
                if part.stopped {
                    stopped = true
                    left.append(item)
                    continue
                }
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
