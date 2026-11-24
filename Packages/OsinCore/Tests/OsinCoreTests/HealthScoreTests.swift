import Testing
@testable import OsinCore

struct HealthScoreTests {
    private let gib: UInt64 = 1 << 30

    private func inputs(
        diskFree: Double = 0.5,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        cpu: Double = 0.1,
        thermal: ThermalLevel = .nominal,
        battery: Double? = 0.95
    ) -> HealthInputs {
        HealthInputs(
            diskFreeFraction: diskFree,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            physicalMemoryBytes: 16 * gib,
            sustainedCPU: cpu,
            thermal: thermal,
            batteryHealth: battery
        )
    }

    @Test func healthyMacScoresHundred() {
        let report = HealthScore.evaluate(inputs())
        #expect(report.score == 100)
        #expect(report.level == .good)
        #expect(report.deductions.values.allSatisfy { $0 == 0 })
    }

    @Test func criticallyFullDiskCostsTheFullDiskWeight() {
        let report = HealthScore.evaluate(inputs(diskFree: 0.04))
        #expect(report.deductions[.disk] == 30)
        #expect(report.score == 70)
        #expect(report.level == .fair)
    }

    @Test func diskPenaltyIsLinearBetweenThresholds() {
        // Halfway between 20% (ok) and 5% (critical) free: half of 30.
        let report = HealthScore.evaluate(inputs(diskFree: 0.125))
        #expect(report.deductions[.disk] == 15)
    }

    @Test func memoryWarningAndSwapAddUp() {
        // warning = 0.5, swap 1.6 GiB of 16 GiB = 0.1: penalty 0.6 of 30 = 18.
        let report = HealthScore.evaluate(inputs(pressure: .warning, swap: gib * 16 / 10))
        #expect(report.deductions[.memory] == 18)
    }

    @Test func memoryPenaltyIsCapped() {
        let report = HealthScore.evaluate(inputs(pressure: .critical, swap: 32 * gib))
        #expect(report.deductions[.memory] == 30)
    }

    @Test func thermalAndCPUDeductions() {
        // CPU 85% sustained: halfway between 70% and 100% of 15 = 7.5. Serious thermal: 0.7 of 10 = 7.
        let report = HealthScore.evaluate(inputs(cpu: 0.85, thermal: .serious))
        #expect(abs(report.exactDeductions[.cpu, default: -1] - 7.5) < 1e-9)
        #expect(report.deductions[.thermal] == 7)
        #expect(report.score == 86) // 100 - 14.5, rounded
    }

    @Test func batteryAt75PercentHealthCostsHalfItsWeight() {
        let report = HealthScore.evaluate(inputs(battery: 0.75))
        #expect(abs(report.exactDeductions[.battery, default: -1] - 7.5) < 1e-9)
    }

    @Test func desktopWithoutBatteryRedistributesWeights() {
        let report = HealthScore.evaluate(inputs(diskFree: 0.0, battery: nil))
        // Disk weight 30 out of 85 remaining points: 30 / 85 * 100 = 35.29
        #expect(report.deductions[.battery] == nil)
        #expect(report.deductions[.disk] == 35)
        #expect(report.score == 65)
    }

    @Test(arguments: [(100, HealthLevel.good), (80, .good), (79, .fair), (60, .fair), (59, .poor), (0, .poor)])
    func levelThresholds(score: Int, level: HealthLevel) {
        #expect(HealthLevel(score: score) == level)
    }
}
