import CoreGraphics
import Foundation

/// The online identity associated with a session-scoped CoreGraphics ID.
struct DisplayWorkTarget: Equatable {
    let displayID: CGDirectDisplayID
    let vendorID: UInt32
    let productID: UInt32

    static func current(for displayID: CGDirectDisplayID) -> DisplayWorkTarget? {
        guard CGDisplayIsOnline(displayID) != 0 else { return nil }
        return DisplayWorkTarget(
            displayID: displayID,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID)
        )
    }
}

/// Serial execution of display work with an injectable clock/executor.
final class DisplayWorkScheduler {
    typealias Cancel = () -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Cancel
    typealias Operation = (@escaping () -> Bool) -> Void

    private let schedule: Schedule
    private let lookup: (CGDirectDisplayID) -> DisplayWorkTarget?
    private let lock = NSLock()
    private var generation: UUID?
    private var pending: [CGDirectDisplayID: Ticket] = [:]

    private final class Ticket {
        let target: DisplayWorkTarget
        let session: UUID
        var cancel: Cancel?
        init(target: DisplayWorkTarget, session: UUID) {
            self.target = target
            self.session = session
        }
    }

    init(
        schedule: Schedule? = nil,
        currentTarget: @escaping (CGDirectDisplayID) -> DisplayWorkTarget? = DisplayWorkTarget.current
    ) {
        let queue = DispatchQueue(label: "com.acuity.display-reapply", qos: .utility)
        self.schedule = schedule ?? { delay, operation in
            let item = DispatchWorkItem(block: operation)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
        self.lookup = currentTarget
    }

    var currentSession: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func isCurrent(_ session: UUID) -> Bool {
        currentSession == session
    }

    @discardableResult
    func start() -> UUID {
        lock.lock()
        let cancelled = invalidateAllLocked()
        let session = UUID()
        generation = session
        lock.unlock()
        cancelled.forEach { $0() }
        return session
    }

    func stop() {
        lock.lock()
        generation = nil
        let cancelled = invalidateAllLocked()
        lock.unlock()
        cancelled.forEach { $0() }
    }

    deinit { stop() }

    func currentTarget(for displayID: CGDirectDisplayID) -> DisplayWorkTarget? {
        lookup(displayID)
    }

    func cancel(displayID: CGDirectDisplayID, session: UUID) {
        lock.lock()
        guard generation == session else {
            lock.unlock()
            return
        }
        let ticket = pending.removeValue(forKey: displayID)
        let cancel = ticket?.cancel
        ticket?.cancel = nil
        lock.unlock()
        cancel?()
    }

    func enqueue(
        _ target: DisplayWorkTarget,
        after delay: TimeInterval = 2,
        session: UUID,
        replacing: Bool = true,
        operation: @escaping Operation
    ) {
        lock.lock()
        guard generation == session, replacing || pending[target.displayID] == nil else {
            lock.unlock()
            return
        }
        let old = pending[target.displayID]
        let oldCancel = old?.cancel
        old?.cancel = nil
        let ticket = Ticket(target: target, session: session)
        pending[target.displayID] = ticket
        lock.unlock()
        oldCancel?()

        let cancel = schedule(delay) { [weak self] in
            guard let self else { return }
            defer { finish(ticket) }
            guard canApply(ticket) else { return }
            // No bookkeeping lock spans client work or a CoreGraphics call.
            // An already-running mode change cannot be undone by cancellation.
            operation { [weak self] in self?.canApply(ticket) ?? false }
        }
        lock.lock()
        let stillPending = pending[target.displayID] === ticket
        if stillPending { ticket.cancel = cancel }
        lock.unlock()
        // Replacement/stop may have raced scheduling before its handle existed.
        if !stillPending { cancel() }
    }

    private func canApply(_ ticket: Ticket) -> Bool {
        lock.lock()
        let current = generation == ticket.session && pending[ticket.target.displayID] === ticket
        lock.unlock()
        guard current, lookup(ticket.target.displayID) == ticket.target else { return false }
        // A topology/lifetime event may occur during the identity lookup itself.
        lock.lock()
        defer { lock.unlock() }
        return generation == ticket.session && pending[ticket.target.displayID] === ticket
    }

    private func finish(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        if pending[ticket.target.displayID] === ticket {
            pending.removeValue(forKey: ticket.target.displayID)
        }
        // Break ticket -> cancellation handle -> queued callback -> ticket.
        ticket.cancel = nil
    }

    private func invalidateAllLocked() -> [Cancel] {
        let cancelled = pending.values.compactMap { ticket -> Cancel? in
            let cancel = ticket.cancel
            ticket.cancel = nil
            return cancel
        }
        pending.removeAll()
        return cancelled
    }
}
