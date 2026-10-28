import Foundation

/// Pure delay policy for foreground shared-state polling. The caller owns scheduling.
public struct SharedPollingPolicy: Sendable {
    public enum Outcome: Sendable {
        case changed, unchanged, transientFailure
    }

    public private(set) var nextDelay: TimeInterval = 5
    private var failureCount = 0

    public init() {}

    public mutating func record(_ outcome: Outcome) {
        switch outcome {
        case .changed:
            failureCount = 0
            nextDelay = 5
        case .unchanged:
            failureCount = 0
            nextDelay = min(nextDelay + 5, 30)
        case .transientFailure:
            failureCount = min(failureCount, 5) + 1
            switch failureCount {
            case 1: nextDelay = 5
            case 2: nextDelay = 10
            case 3: nextDelay = 20
            case 4: nextDelay = 40
            case 5: nextDelay = 80
            default: nextDelay = 120
            }
        }
    }

    public mutating func reset() {
        failureCount = 0
        nextDelay = 5
    }
}
