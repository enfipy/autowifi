import Foundation

@MainActor
final class RemovalRecovery {
    private let defaults: UserDefaults
    private let deadlineKey: String
    private let now: () -> Date
    private let update: (Int) -> Void
    private var timer: Timer?

    init(
        defaults: UserDefaults = .standard,
        deadlineKey: String = "autowifi.removalRecoveryDeadline",
        now: @escaping () -> Date = Date.init,
        update: @escaping (Int) -> Void
    ) {
        self.defaults = defaults
        self.deadlineKey = deadlineKey
        self.now = now
        self.update = update
    }

    func restore() {
        let timestamp = defaults.double(forKey: deadlineKey)
        guard timestamp > 0 else {
            update(0)
            return
        }
        resume(until: Date(timeIntervalSince1970: timestamp))
    }

    func start() {
        let deadline = RemovalRecoveryPolicy.deadline(startedAt: now())
        defaults.set(deadline.timeIntervalSince1970, forKey: deadlineKey)
        resume(until: deadline)
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        defaults.removeObject(forKey: deadlineKey)
        update(0)
    }

    private func resume(until deadline: Date) {
        publish(deadline: deadline)
        guard remainingSeconds(deadline: deadline) > 0 else {
            clear()
            return
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.publish(deadline: deadline)
                if self.remainingSeconds(deadline: deadline) == 0 {
                    self.clear()
                }
            }
        }
    }

    private func publish(deadline: Date) {
        update(remainingSeconds(deadline: deadline))
    }

    private func remainingSeconds(deadline: Date) -> Int {
        RemovalRecoveryPolicy.remainingSeconds(deadline: deadline, now: now())
    }
}
