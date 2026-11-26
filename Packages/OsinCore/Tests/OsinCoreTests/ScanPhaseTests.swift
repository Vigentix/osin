import Testing
@testable import OsinCore

struct ScanPhaseTests {
    @Test func nothingInterruptsAClean() {
        let phase = ScanPhase.cleaning
        #expect(phase.isBusy)
        #expect(!phase.canStartScan)
        #expect(!phase.canStartBackgroundScan)
        #expect(!phase.canCleanSafeNow)
        #expect(!phase.canShowReport)
        #expect(!phase.canCancel)
    }

    @Test func aScanCanBeCancelledOrRestartedButNotCleanedOver() {
        let phase = ScanPhase.scanning
        #expect(phase.canCancel)
        #expect(phase.canStartScan)
        #expect(!phase.canCleanSafeNow)
        #expect(!phase.canShowReport)
        #expect(!phase.canStartBackgroundScan)
    }

    @Test func idleReportAndDoneAllowUserActions() {
        for phase in [ScanPhase.idle, .report, .done] {
            #expect(!phase.isBusy)
            #expect(phase.canStartScan)
            #expect(phase.canCleanSafeNow)
            #expect(phase.canShowReport)
            #expect(!phase.canCancel)
        }
        #expect(ScanPhase.idle.canStartBackgroundScan)
        #expect(ScanPhase.done.canStartBackgroundScan)
        #expect(!ScanPhase.report.canStartBackgroundScan)
    }
}
