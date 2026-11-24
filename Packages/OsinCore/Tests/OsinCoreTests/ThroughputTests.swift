import Testing
@testable import OsinCore

struct ThroughputTests {
    @Test func bytesPerSecondFromCounterDelta() {
        #expect(Throughput.rate(previous: 1000, current: 5000, seconds: 2) == 2000)
    }

    @Test func counterResetGivesZeroInsteadOfHugeSpike() {
        #expect(Throughput.rate(previous: 5000, current: 100, seconds: 2) == 0)
    }

    @Test func nonPositiveIntervalGivesZero() {
        #expect(Throughput.rate(previous: 0, current: 100, seconds: 0) == 0)
        #expect(Throughput.rate(previous: 0, current: 100, seconds: -1) == 0)
    }
}
