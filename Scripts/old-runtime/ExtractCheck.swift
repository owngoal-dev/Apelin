// The real extractor over a real Apple package, on a thread with no pool that
// drains, as apelin-environment runs it, with its peak footprint measured.
// 0.3.6 and 0.3.7 reached 2.4 GB here on Command Line Tools 27.0 and 5.5 GB on
// 16.4, more than an iPhone gives a process; it belongs near 100 MB.
import Darwin
import Foundation

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0
    private var running = true

    func sample() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        highest = max(highest, footprint())
        return running
    }

    func stop() -> Int {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return highest
    }
}

let bound = 512 * 1024 * 1024
let arguments = CommandLine.arguments
let done = DispatchSemaphore(value: 0)
var failed = false
Task.detached {
    let peak = Peak()
    Thread.detachNewThread {
        while peak.sample() {
            usleep(50000)
        }
    }
    do {
        try PackageArchive(limits: .init()).extract(
            URL(fileURLWithPath: arguments[1]),
            to: URL(fileURLWithPath: arguments[2]),
        )
    } catch {
        print("error: \(error)")
        failed = true
    }
    let highest = peak.stop()
    print("extracted, peak footprint \(highest / 1_048_576) MB")
    if highest > bound {
        print("error: unpacking must stay under \(bound / 1_048_576) MB; something keeps what it read")
        failed = true
    }
    done.signal()
}
done.wait()
exit(failed ? 1 : 0)
