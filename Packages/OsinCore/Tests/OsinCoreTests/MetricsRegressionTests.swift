import Foundation
import Testing
@testable import OsinCore

/// Regression tests for metrics issues found in the v0.1.0 review.
struct MetricsRegressionTests {
    // MARK: Alert cooldowns survive a relaunch

    @Test func restoredCooldownsSuppressRepeatAlerts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = AlertReading(diskFreeFraction: 0.5, freeBytes: 1, memoryPressure: .normal, batteryHealth: 0.75)

        var first = AlertEvaluator(settings: AlertSettings())
        #expect(first.evaluate(reading, at: now).map(\.kind) == [.batteryHealth])

        // Next launch, a day later: a fresh evaluator restored from the saved times stays quiet.
        var relaunched = AlertEvaluator(settings: AlertSettings(), lastAlerts: first.lastAlerts)
        #expect(relaunched.evaluate(reading, at: now.addingTimeInterval(86400)).isEmpty)
        // After the 30-day cooldown it alerts again.
        #expect(relaunched.evaluate(reading, at: now.addingTimeInterval(31 * 86400)).map(\.kind) == [.batteryHealth])
    }

    // MARK: Sampling interval

    @Test func samplesTakenTooCloseTogetherReuseThePreviousSnapshot() async {
        let sampler = SystemSampler(minimumInterval: .seconds(5))
        let first = await sampler.sample()
        let second = await sampler.sample()
        #expect(second.date == first.date)
    }

    // MARK: Battery health as macOS reports it

    @Test func parsesMaximumCapacityFromSystemProfiler() {
        let json = """
        {"SPPowerDataType": [
          {"_name": "spbattery_information", "sppower_battery_health_info": {
            "sppower_battery_cycle_count": 271, "sppower_battery_health": "Good",
            "sppower_battery_health_maximum_capacity": "84%"}},
          {"_name": "sppower_ac_charger_information"}
        ]}
        """
        #expect(BatteryHealth.maximumCapacity(fromSystemProfilerJSON: Data(json.utf8)) == 0.84)
        #expect(BatteryHealth.maximumCapacity(fromSystemProfilerJSON: Data("{}".utf8)) == nil)
    }

    // MARK: History weighting

    private func point(_ date: Date, cpu: Double) -> HistoryPoint {
        HistoryPoint(
            date: date, cpu: cpu, memoryUsed: 0.5, pressure: .normal, diskFree: 0.3,
            networkReceive: 0, networkSend: 0, batteryCharge: nil, score: 90
        )
    }

    @Test func bucketAveragesAreWeightedByTheTimeEachSampleCovers() async throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // One 30 s background sample at 0% and one 2 s foreground sample at 100% in the same minute.
        try await store.record(point(base, cpu: 0), seconds: 30)
        try await store.record(point(base.addingTimeInterval(30), cpu: 1), seconds: 2)
        let points = try await store.points(since: base.addingTimeInterval(-60), bucket: 60)
        let cpu = try #require(points.first?.cpu)
        #expect(abs(cpu - 2.0 / 32.0) < 1e-9)
    }

    @Test func compactionKeepsWeights() async throws {
        let store = try HistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-2 * 3600)
        let minute = Date(timeIntervalSince1970: (old.timeIntervalSince1970 / 60).rounded(.down) * 60)
        try await store.record(point(minute, cpu: 0), seconds: 30)
        try await store.record(point(minute.addingTimeInterval(30), cpu: 1), seconds: 2)
        try await store.compact(now: now)
        // The merged row still stands for 32 s, so it weighs as much as another 32 s sample.
        try await store.record(point(minute.addingTimeInterval(45), cpu: 1), seconds: 32)
        let points = try await store.points(since: minute.addingTimeInterval(-60), bucket: 60)
        let cpu = try #require(points.first?.cpu)
        #expect(abs(cpu - 34.0 / 64.0) < 1e-9)
    }
}
