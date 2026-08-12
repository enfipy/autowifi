import Foundation

public enum RemovalRecoveryPolicy {
    public static let duration: TimeInterval = 60

    public static func deadline(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(duration)
    }

    public static func remainingSeconds(deadline: Date, now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}
