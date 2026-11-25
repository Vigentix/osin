import Foundation
import Testing
@testable import OsinCore

struct RecommendationTests {
    private let gib: UInt64 = 1 << 30

    private func context(
        safeBytes: UInt64? = 7 * (1 << 30),
        reviewBytes: UInt64 = 0,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        heaviest: ProcessGroup? = nil,
        battery: Double? = 0.95
    ) -> RecommendationContext {
        RecommendationContext(
            safeReclaimableBytes: safeBytes,
            reviewBytes: reviewBytes,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            physicalMemoryBytes: 16 * gib,
            heaviestApp: heaviest,
            batteryHealth: battery
        )
    }

    private let chrome = ProcessGroup(
        id: "/Applications/Google Chrome.app", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app",
        pids: [1, 2], footprintBytes: 5 * (1 << 30), cpuFraction: 0.02
    )

    @Test func reclaimableSpaceComesFirst() {
        let list = Recommendations.make(context(heaviest: chrome, battery: 0.82))
        #expect(list.first?.kind == .cleanSafe(bytes: 7 * gib))
    }

    @Test func smallReclaimableAmountsAreNotWorthARecommendation() {
        let list = Recommendations.make(context(safeBytes: 100 * (1 << 20)))
        #expect(!list.contains {
            if case .cleanSafe = $0.kind {
                true
            } else {
                false
            }
        })
    }

    @Test func noScanYetSuggestsScanning() {
        #expect(Recommendations.make(context(safeBytes: nil)).first?.kind == .scan)
    }

    @Test func heavyAppIsSuggestedOnlyUnderMemoryStrain() {
        #expect(!Recommendations.make(context(heaviest: chrome)).contains { $0.kind == .quitApp(chrome) })
        #expect(Recommendations.make(context(pressure: .warning, heaviest: chrome)).contains { $0.kind == .quitApp(chrome) })
        // Swap above a quarter of RAM counts as strain even with normal pressure.
        #expect(Recommendations.make(context(swap: 5 * gib, heaviest: chrome)).contains { $0.kind == .quitApp(chrome) })
    }

    @Test func reviewAndBatteryAppearWhenRelevant() {
        let list = Recommendations.make(context(reviewBytes: 2 * gib, battery: 0.78))
        #expect(list.contains { $0.kind == .review(bytes: 2 * gib) })
        #expect(list.contains { $0.kind == .battery(health: 0.78) })
    }

    @Test func atMostThreeAreShown() {
        let list = Recommendations.make(context(reviewBytes: 2 * gib, pressure: .critical, heaviest: chrome, battery: 0.7))
        #expect(list.count == 3)
    }

    @Test func healthyMacGetsNothing() {
        #expect(Recommendations.make(context(safeBytes: 0)).isEmpty)
    }
}

struct ProcessMembersTests {
    @Test func groupKeepsItsLargestMembersFirst() {
        let base = "/Applications/Slack.app/Contents"
        let records = [
            ProcessRecord(pid: 1, name: "Slack", executablePath: "\(base)/MacOS/Slack", footprintBytes: 200, cpuFraction: 0),
            ProcessRecord(
                pid: 2,
                name: "Slack Helper (Renderer)",
                executablePath: "\(base)/Frameworks/H.app/Contents/MacOS/H",
                footprintBytes: 600,
                cpuFraction: 0
            ),
            ProcessRecord(
                pid: 3,
                name: "Slack Helper (GPU)",
                executablePath: "\(base)/Frameworks/G.app/Contents/MacOS/G",
                footprintBytes: 100,
                cpuFraction: 0
            )
        ]
        let group = ProcessGrouping.group(records).first
        #expect(group?.members.map(\.pid) == [2, 1, 3])
    }
}
