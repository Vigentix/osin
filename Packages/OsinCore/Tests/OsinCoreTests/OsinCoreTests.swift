import Testing
@testable import OsinCore

@Test func versionIsSemantic() {
    let parts = OsinCore.version.split(separator: "-")[0].split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
