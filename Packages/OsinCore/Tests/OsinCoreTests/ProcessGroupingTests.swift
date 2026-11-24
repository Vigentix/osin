import Testing
@testable import OsinCore

struct ProcessGroupingTests {
    @Test func helperInsideNestedAppBelongsToOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
            + "Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessGrouping.appBundlePath(forExecutable: path) == "/Applications/Google Chrome.app")
    }

    @Test func plainExecutableHasNoAppBundle() {
        #expect(ProcessGrouping.appBundlePath(forExecutable: "/usr/libexec/trustd") == nil)
        #expect(ProcessGrouping.appBundlePath(forExecutable: nil) == nil)
    }

    @Test func groupsByAppAndSumsResources() {
        let records = [
            ProcessRecord(
                pid: 10,
                name: "Google Chrome",
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                footprintBytes: 500,
                cpuFraction: 0.10
            ),
            ProcessRecord(
                pid: 11,
                name: "Google Chrome Helper",
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/"
                    + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                footprintBytes: 300,
                cpuFraction: 0.05
            ),
            ProcessRecord(pid: 20, name: "trustd", executablePath: "/usr/libexec/trustd", footprintBytes: 50, cpuFraction: 0.0)
        ]
        let groups = ProcessGrouping.group(records)
        let chrome = groups.first { $0.name == "Google Chrome" }
        #expect(chrome?.footprintBytes == 800)
        #expect(chrome?.pids == [10, 11])
        #expect(chrome?.bundlePath == "/Applications/Google Chrome.app")
        #expect(abs((chrome?.cpuFraction ?? 0) - 0.15) < 1e-9)
        #expect(groups.first { $0.name == "trustd" }?.bundlePath == nil)
        #expect(groups.count == 2)
    }

    @Test func nonAppProcessIsNamedAfterItsFullExecutableName() {
        // proc_name truncates long names; the executable path does not.
        let record = ProcessRecord(
            pid: 30,
            name: "com.apple.Virtualization.Virtua",
            executablePath: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
                + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
            footprintBytes: 1,
            cpuFraction: 0
        )
        #expect(ProcessGrouping.group([record]).first?.name == "com.apple.Virtualization.VirtualMachine")
    }

    @Test func topByMemoryIsSortedAndLimited() {
        let records = (1 ... 5).map {
            ProcessRecord(pid: Int32($0), name: "p\($0)", executablePath: nil, footprintBytes: UInt64($0) * 100, cpuFraction: 0)
        }
        let top = ProcessGrouping.top(ProcessGrouping.group(records), by: .memory, limit: 3)
        #expect(top.map(\.name) == ["p5", "p4", "p3"])
    }
}
