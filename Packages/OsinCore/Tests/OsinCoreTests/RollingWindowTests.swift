import Testing
@testable import OsinCore

struct RollingWindowTests {
    @Test func keepsOnlyTheNewestValuesInOrder() {
        var window = RollingWindow<Double>(capacity: 3)
        for value in [1.0, 2, 3, 4, 5] {
            window.append(value)
        }
        #expect(window.values == [3, 4, 5])
    }

    @Test func averageOfStoredValues() {
        var window = RollingWindow<Double>(capacity: 4)
        for value in [0.2, 0.4, 0.6] {
            window.append(value)
        }
        #expect(abs((window.average ?? -1) - 0.4) < 1e-9)
    }

    @Test func emptyWindowHasNoAverage() {
        let window = RollingWindow<Double>(capacity: 4)
        #expect(window.average == nil)
        #expect(window.values.isEmpty)
    }
}
