import Foundation
import Testing
@testable import OsinCore

/// Integration tests against the real machine. They assert invariants, not specific values.
@Suite(.serialized) struct SystemSamplerTests {
    @Test func secondSampleHasPlausibleValues() async throws {
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await sampler.sample()

        #expect((0 ... 1).contains(snapshot.cpu.total))
        #expect(snapshot.cpu.perCore.count == ProcessInfo.processInfo.processorCount)
        #expect(snapshot.memory.physicalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memory.usedBytes > 0)
        #expect(snapshot.memory.usedBytes <= snapshot.memory.physicalBytes)
        #expect(snapshot.disk.totalBytes > 0)
        #expect(snapshot.disk.availableBytes <= snapshot.disk.totalBytes)
        #expect(snapshot.network.receiveBytesPerSecond >= 0)
        #expect(!snapshot.topByMemory.isEmpty)
        #expect(snapshot.topByMemory.count <= 5)
        #expect((0 ... 100).contains(snapshot.health.score))
    }

    @Test func firstSampleReportsNoRatesYet() async {
        let snapshot = await SystemSampler().sample()
        #expect(snapshot.network.receiveBytesPerSecond == 0)
        #expect(snapshot.network.sendBytesPerSecond == 0)
        #expect(snapshot.disk.readBytesPerSecond == 0)
        #expect(snapshot.cpu.total == 0)
    }

    @Test func processReaderSeesThisTestProcess() {
        let own = ProcessReader.readAll().first { $0.pid == getpid() }
        #expect(own != nil)
        #expect((own?.footprintBytes ?? 0) > 0)
        #expect((own?.cpuNanoseconds ?? 0) > 0)
    }

    @Test func batteryReadingIsWithinRangeWhenPresent() {
        guard let battery = BatteryReader.read() else { return } // Desktops and CI VMs have none.
        #expect((0 ... 1).contains(battery.chargeFraction))
        if let health = battery.health {
            #expect((0 ... 1).contains(health))
        }
    }

    @Test func coreTopologyMatchesHardware() {
        let topology = CoreTopology.current()
        #if arch(arm64)
            #expect(topology != nil)
        #else
            #expect(topology == nil)
        #endif
    }
}
