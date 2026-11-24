import Testing
@testable import OsinCore

struct MemoryStatsTests {
    @Test func derivesActivityMonitorStyleFigures() {
        // 16 KiB pages.
        let pages = VMPageCounts(
            free: 100,
            active: 0,
            inactive: 0,
            speculative: 0,
            wired: 200,
            compressed: 50,
            internalPages: 1000,
            purgeable: 100,
            external: 300
        )
        let stats = MemoryStats(
            pages: pages,
            pageSize: 16384,
            physicalBytes: 17_179_869_184,
            swapUsedBytes: 1_000_000,
            swapTotalBytes: 2_000_000,
            pressure: .normal
        )
        #expect(stats.appBytes == 900 * 16384) // internal - purgeable
        #expect(stats.wiredBytes == 200 * 16384)
        #expect(stats.compressedBytes == 50 * 16384)
        #expect(stats.usedBytes == 1150 * 16384) // app + wired + compressed
        #expect(stats.cachedBytes == 400 * 16384) // external + purgeable
    }

    @Test func purgeableLargerThanInternalDoesNotUnderflow() {
        let pages = VMPageCounts(
            free: 0, active: 0, inactive: 0, speculative: 0, wired: 0,
            compressed: 0, internalPages: 10, purgeable: 20, external: 0
        )
        let stats = MemoryStats(
            pages: pages, pageSize: 4096, physicalBytes: 1 << 30,
            swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal
        )
        #expect(stats.appBytes == 0)
    }

    @Test(arguments: [
        (Int32(1), MemoryPressure.normal),
        (Int32(2), MemoryPressure.warning),
        (Int32(4), MemoryPressure.critical),
        (Int32(0), MemoryPressure.normal)
    ])
    func pressureFromKernelLevel(raw: Int32, expected: MemoryPressure) {
        #expect(MemoryPressure(kernelLevel: raw) == expected)
    }
}
