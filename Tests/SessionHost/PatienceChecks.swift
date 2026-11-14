import Foundation

// A stop the session's worker does not take (Apelind/Session/Patience.swift,
// used by AgentHandler.abort): the host waits so long for the worker's
// answer and no longer, whether or not one ever comes. A conversation whose
// worker never answered could be neither stopped nor continued (#59).

func patienceChecks() async {
    let quick = await Patience.answer(within: 5) { 7 }
    check(quick == 7, "an answer in time is the answer")

    let silent = SilentWorker()
    let started = Date()
    let none: Int? = await Patience.answer(within: 0.3) {
        await silent.wait()
        return 1
    }
    check(none == nil, "no answer in time is nil")
    check(Date().timeIntervalSince(started) < 5, "and the caller is not held past the bound")

    // The late answer goes unread, and nothing waits on it twice.
    silent.answer()
    let late = await Patience.answer(within: 5) {
        await silent.wait()
        return 2
    }
    check(late == 2, "a later wait is its own")
}

/// Answers only once told to, as a worker that does not read its channel.
private final class SilentWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if !answered {
                    waiting.append(continuation)
                }
                return answered
            }
            if resume {
                continuation.resume()
            }
        }
    }

    func answer() {
        let waiting = lock.withLock {
            answered = true
            defer { self.waiting = [] }
            return self.waiting
        }
        waiting.forEach { $0.resume() }
    }
}
