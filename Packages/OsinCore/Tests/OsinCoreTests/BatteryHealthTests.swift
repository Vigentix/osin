import Testing
@testable import OsinCore

struct BatteryHealthTests {
    @Test func prefersNominalChargeCapacity() {
        let props: [String: Any] = ["NominalChargeCapacity": 4191, "AppleRawMaxCapacity": 4058, "DesignCapacity": 5103, "MaxCapacity": 100]
        let health = BatteryHealth.fraction(fromRegistry: props)
        #expect(abs((health ?? 0) - 4191.0 / 5103.0) < 1e-9)
    }

    @Test func fallsBackToRawMaxCapacity() {
        let props: [String: Any] = ["AppleRawMaxCapacity": 4000, "DesignCapacity": 5000, "MaxCapacity": 100]
        #expect(BatteryHealth.fraction(fromRegistry: props) == 0.8)
    }

    @Test func intelMaxCapacityInMilliampHours() {
        // On Intel Macs MaxCapacity is mAh, not a percentage.
        let props: [String: Any] = ["MaxCapacity": 4500, "DesignCapacity": 5000]
        #expect(BatteryHealth.fraction(fromRegistry: props) == 0.9)
    }

    @Test func percentageMaxCapacityAloneIsNotTrusted() {
        let props: [String: Any] = ["MaxCapacity": 100, "DesignCapacity": 5000]
        #expect(BatteryHealth.fraction(fromRegistry: props) == nil)
    }

    @Test func missingDesignCapacityGivesNil() {
        #expect(BatteryHealth.fraction(fromRegistry: ["NominalChargeCapacity": 4000]) == nil)
    }

    @Test func healthIsClampedToOne() {
        let props: [String: Any] = ["NominalChargeCapacity": 5300, "DesignCapacity": 5103]
        #expect(BatteryHealth.fraction(fromRegistry: props) == 1)
    }
}
