// What one call through an @objc dynamic thunk leaves behind, by the type it
// carries, on the runtime this runs on. `Data` is the control: on the iOS 15.5
// runtime each call leaves a small object that keeps the bytes alive until the
// autorelease pool drains, and a check that stopped seeing that could no
// longer see anything. Every other type must leave nothing, since AGENTS.md
// leaves only `Data` plain.
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

final class Calls: NSObject {
    let url = URL(fileURLWithPath: "/var/mobile/Documents/wiki.qaq.apelin/Environment/Toolchains")
    let text = "/var/mobile/Documents/wiki.qaq.apelin/Environment/Toolchains"
    let table = ["alpha": "one", "beta": "two"]
    let names: Set<String> = ["alpha", "beta"]
    let list = ["alpha", "beta"]
    let time = Date()
    let id = UUID()
    let bytes = Data(repeating: 1, count: 1024)
    let octets = [UInt8](repeating: 1, count: 16)
    let reference = NSData(bytes: [1, 2, 3, 4] as [UInt8], length: 4)

    @objc dynamic func returnsData() -> Data { Data([1, 2, 3, 4]) }
    @objc dynamic func returnsURL() -> URL { url }
    @objc dynamic func returnsString() -> String { text }
    @objc dynamic func returnsDictionary() -> [String: String] { table }
    @objc dynamic func returnsSet() -> Set<String> { names }
    @objc dynamic func returnsArray() -> [String] { list }
    @objc dynamic func returnsDate() -> Date { time }
    @objc dynamic func returnsUUID() -> UUID { id }
    @objc dynamic func returnsBytes() -> [UInt8] { octets }
    @objc dynamic func returnsNSData() -> NSData { reference }
    @objc dynamic func takes(data: Data) -> Int { data.count }
    @objc dynamic func takes(url: URL) -> Int { url.path.utf8.count }
    @objc dynamic func takes(string: String) -> Int { string.utf8.count }
    @objc dynamic func takes(bytes: [UInt8]) -> Int { bytes.count }
    @objc dynamic func takes(table: [String: String]) -> Int { table.count }
    @objc dynamic func takes(names: Set<String>) -> Int { names.count }
    @objc dynamic func takes(list: [String]) -> Int { list.count }
    @objc dynamic func takes(time: Date) -> Int { Int(time.timeIntervalSince1970) }
    @objc dynamic func takes(id: UUID) -> Int { id.uuid.0 == 0 ? 0 : 1 }
}

let iterations = 400_000

func bytesLeft(_ body: () -> Int) -> Int {
    var sum = 0
    let before = footprint()
    for _ in 0 ..< iterations {
        sum &+= body()
    }
    return (footprint() - before) / iterations + (sum & 0)
}

let done = DispatchSemaphore(value: 0)
var failed = false
Task.detached {
    let calls = Calls()
    let control: [(String, () -> Int)] = [
        ("Data returned", { calls.returnsData().count }),
        ("Data argument", { calls.takes(data: calls.bytes) }),
    ]
    let others: [(String, () -> Int)] = [
        ("URL returned", { calls.returnsURL().path.utf8.count }),
        ("String returned", { calls.returnsString().utf8.count }),
        ("Dictionary returned", { calls.returnsDictionary().count }),
        ("Set returned", { calls.returnsSet().count }),
        ("Array returned", { calls.returnsArray().count }),
        ("Date returned", { Int(calls.returnsDate().timeIntervalSince1970) }),
        ("UUID returned", { calls.returnsUUID().uuid.0 == 0 ? 0 : 1 }),
        ("[UInt8] returned", { calls.returnsBytes().count }),
        ("NSData returned", { calls.returnsNSData().length }),
        ("URL argument", { calls.takes(url: calls.url) }),
        ("String argument", { calls.takes(string: calls.text) }),
        ("[UInt8] argument", { calls.takes(bytes: calls.octets) }),
        ("Dictionary argument", { calls.takes(table: calls.table) }),
        ("Set argument", { calls.takes(names: calls.names) }),
        ("Array argument", { calls.takes(list: calls.list) }),
        ("Date argument", { calls.takes(time: calls.time) }),
        ("UUID argument", { calls.takes(id: calls.id) }),
    ]
    for (name, body) in control {
        let left = bytesLeft(body)
        print("\(name): \(left) bytes a call stay in the autorelease pool")
        if left == 0 {
            print("error: this runtime no longer shows the leak the checks are here for")
            failed = true
        }
    }
    for (name, body) in others {
        let left = bytesLeft(body)
        print("\(name): \(left) bytes a call")
        if left > 0 {
            print("error: \(name) stays in the autorelease pool too; leave it plain as Data is")
            failed = true
        }
    }
    done.signal()
}
done.wait()
exit(failed ? 1 : 0)
