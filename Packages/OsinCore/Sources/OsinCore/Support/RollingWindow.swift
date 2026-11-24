/// Fixed-capacity buffer that keeps the newest values, oldest first.
public struct RollingWindow<Element> {
    public let capacity: Int
    public private(set) var values: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0, "RollingWindow capacity must be positive")
        self.capacity = capacity
        values.reserveCapacity(capacity)
    }

    public mutating func append(_ value: Element) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(value)
    }
}

extension RollingWindow: Sendable where Element: Sendable {}
extension RollingWindow: Equatable where Element: Equatable {}

public extension RollingWindow where Element: BinaryFloatingPoint {
    /// Arithmetic mean, or `nil` when empty.
    var average: Element? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Element(values.count)
    }
}
