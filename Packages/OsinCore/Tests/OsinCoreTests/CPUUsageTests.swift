import Testing
@testable import OsinCore

struct CPUUsageTests {
    @Test func idleOnlyDeltaIsZeroUsage() {
        let before = [CPUTicks(user: 10, system: 10, idle: 100, nice: 0)]
        let after = [CPUTicks(user: 10, system: 10, idle: 200, nice: 0)]
        #expect(CPUUsage.perCore(previous: before, current: after) == [0])
    }

    @Test func busyHalfOfTheTime() {
        let before = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 30, system: 15, idle: 50, nice: 5)]
        #expect(CPUUsage.perCore(previous: before, current: after) == [0.5])
    }

    @Test func totalWeighsCoresByTicks() {
        // Core 0: 100 ticks, 100 busy. Core 1: 300 ticks, 0 busy. Total: 100 / 400.
        let before = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 300, nice: 0)]
        #expect(CPUUsage.total(previous: before, current: after) == 0.25)
    }

    @Test func counterWrapAroundIsHandled() {
        let before = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]
        // user delta = 20 (wrapped), idle delta = 20: 50% busy.
        #expect(CPUUsage.perCore(previous: before, current: after) == [0.5])
    }

    @Test func mismatchedCoreCountsYieldNoData() {
        let one = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        #expect(CPUUsage.perCore(previous: one, current: one + one).isEmpty)
        #expect(CPUUsage.total(previous: one, current: one + one) == nil)
    }

    @Test func noElapsedTicksIsZeroNotNaN() {
        let same = [CPUTicks(user: 5, system: 5, idle: 5, nice: 5)]
        #expect(CPUUsage.perCore(previous: same, current: same) == [0])
        #expect(CPUUsage.total(previous: same, current: same) == 0)
    }

    @Test func appleSiliconTopologyPutsEfficiencyCoresFirst() throws {
        let topology = try #require(CoreTopology(logicalCPUs: 8, performanceCPUs: 4, efficiencyCPUs: 4))
        #expect(topology.efficiency == 0 ..< 4)
        #expect(topology.performance == 4 ..< 8)
    }

    @Test func topologyRequiresBothClustersToMatchCPUCount() {
        #expect(CoreTopology(logicalCPUs: 8, performanceCPUs: 8, efficiencyCPUs: 0) == nil)
        #expect(CoreTopology(logicalCPUs: 10, performanceCPUs: 4, efficiencyCPUs: 4) == nil)
    }

    @Test func clusterAverageUsesOnlyItsCores() throws {
        let topology = try #require(CoreTopology(logicalCPUs: 4, performanceCPUs: 2, efficiencyCPUs: 2))
        let usage = [0.1, 0.3, 0.8, 1.0]
        #expect(abs(topology.averageEfficiency(usage) - 0.2) < 1e-9)
        #expect(abs(topology.averagePerformance(usage) - 0.9) < 1e-9)
    }
}
