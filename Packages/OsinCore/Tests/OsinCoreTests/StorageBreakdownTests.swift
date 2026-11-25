import Foundation
import Testing
@testable import OsinCore

struct StorageBreakdownTests {
    @Test func measuresKnownFoldersAndPutsTheRestInOther() async throws {
        let fixture = try FixtureHome()
        let apps = fixture.root.appendingPathComponent("Applications")
        try fixture.file("Big.app/Contents/MacOS/Big", bytes: 300_000, in: apps)
        try fixture.file("Library/Developer/Xcode/blob", bytes: 200_000)
        try fixture.file("Library/Caches/x/blob", bytes: 100_000)
        let breakdown = try await StorageBreakdown.measure(
            home: fixture.home, applications: apps, totalBytes: 10_000_000, availableBytes: 4_000_000, reclaimableBytes: 50000
        )
        #expect(breakdown.apps >= 300_000)
        #expect(breakdown.developer >= 200_000)
        #expect(breakdown.caches >= 100_000)
        #expect(breakdown.reclaimable == 50000)
        #expect(breakdown.free == 4_000_000)
        // Everything adds up to the disk size.
        #expect(breakdown.apps + breakdown.developer + breakdown.caches + breakdown.other + breakdown.free == 10_000_000)
    }

    @Test func otherNeverGoesNegative() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/x/blob", bytes: 900_000)
        let breakdown = try await StorageBreakdown.measure(
            home: fixture.home, applications: fixture.outside, totalBytes: 100_000, availableBytes: 10000, reclaimableBytes: 0
        )
        #expect(breakdown.other == 0)
    }
}
