import Foundation
import Testing
@testable import OsinCore

struct AlertEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(diskFree: Double = 0.5, pressure: MemoryPressure = .normal, battery: Double? = 0.95) -> AlertReading {
        AlertReading(diskFreeFraction: diskFree, freeBytes: 7_000_000_000, memoryPressure: pressure, batteryHealth: battery)
    }

    @Test func lowDiskAlertsOnceThenWaitsForCooldown() {
        var evaluator = AlertEvaluator(settings: AlertSettings())
        #expect(evaluator.evaluate(reading(diskFree: 0.05), at: start).map(\.kind) == [.lowDisk])
        #expect(evaluator.evaluate(reading(diskFree: 0.05), at: start.addingTimeInterval(3600)).isEmpty)
        #expect(evaluator.evaluate(reading(diskFree: 0.05), at: start.addingTimeInterval(86400 + 1)).map(\.kind) == [.lowDisk])
    }

    @Test func diskAboveThresholdDoesNotAlert() {
        var evaluator = AlertEvaluator(settings: AlertSettings(diskFreeThreshold: 0.10))
        #expect(evaluator.evaluate(reading(diskFree: 0.11), at: start).isEmpty)
    }

    @Test func memoryCriticalMustLastAMinute() {
        var evaluator = AlertEvaluator(settings: AlertSettings())
        #expect(evaluator.evaluate(reading(pressure: .critical), at: start).isEmpty)
        #expect(evaluator.evaluate(reading(pressure: .critical), at: start.addingTimeInterval(30)).isEmpty)
        #expect(evaluator.evaluate(reading(pressure: .critical), at: start.addingTimeInterval(61)).map(\.kind) == [.memoryPressure])
    }

    @Test func memoryRecoveryResetsTheTimer() {
        var evaluator = AlertEvaluator(settings: AlertSettings())
        _ = evaluator.evaluate(reading(pressure: .critical), at: start)
        _ = evaluator.evaluate(reading(pressure: .normal), at: start.addingTimeInterval(40))
        #expect(evaluator.evaluate(reading(pressure: .critical), at: start.addingTimeInterval(70)).isEmpty)
    }

    @Test func warningPressureIsNotAnAlert() {
        var evaluator = AlertEvaluator(settings: AlertSettings())
        _ = evaluator.evaluate(reading(pressure: .warning), at: start)
        #expect(evaluator.evaluate(reading(pressure: .warning), at: start.addingTimeInterval(120)).isEmpty)
    }

    @Test func batteryHealthAlertIsRareAndOptional() {
        var evaluator = AlertEvaluator(settings: AlertSettings())
        #expect(evaluator.evaluate(reading(battery: 0.75), at: start).map(\.kind) == [.batteryHealth])
        #expect(evaluator.evaluate(reading(battery: 0.75), at: start.addingTimeInterval(7 * 86400)).isEmpty)

        var disabled = AlertEvaluator(settings: AlertSettings(batteryHealthEnabled: false))
        #expect(disabled.evaluate(reading(battery: 0.75), at: start).isEmpty)
    }

    @Test func everythingOffMeansSilence() {
        var evaluator = AlertEvaluator(settings: AlertSettings(enabled: false))
        _ = evaluator.evaluate(reading(diskFree: 0.01, pressure: .critical, battery: 0.5), at: start)
        #expect(evaluator.evaluate(reading(diskFree: 0.01, pressure: .critical, battery: 0.5), at: start.addingTimeInterval(120)).isEmpty)
    }
}
