import Darwin
import Foundation

/// How much memory and processor Verb and its local writing model use, read every two
/// seconds while the Models page is open.
@MainActor final class ResourceMonitor: ObservableObject {
    struct Reading: Equatable {
        /// Verb itself, the speech model included when it is loaded.
        var verb: UInt64
        /// The local writing engine Verb started, and its model; nil when none runs.
        var writer: UInt64?
        /// Verb's share of one processor core, in percent.
        var cpu: Double
    }
    @Published private(set) var reading: Reading?
    var writerProcess: () -> pid_t? = { nil }
    private var timer: Timer?
    private var last: (time: TimeInterval, cpu: UInt64)?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
    }
    func stop() { timer?.invalidate(); timer = nil; last = nil }

    func sample() {
        guard let own = Self.usage(getpid()) else { return }
        let writer = writerProcess().map { server in ([server] + Self.children(of: server)).compactMap { Self.usage($0)?.memory }.reduce(0, +) }
        let now = ProcessInfo.processInfo.systemUptime
        var cpu = 0.0
        if let last, now > last.time, own.cpu >= last.cpu { cpu = Double(own.cpu - last.cpu) / 1_000_000_000 / (now - last.time) * 100 }
        last = (now, own.cpu)
        reading = Reading(verb: own.memory, writer: writer, cpu: cpu)
    }

    /// Memory in bytes and processor time in nanoseconds used by a process.
    static func usage(_ pid: pid_t) -> (memory: UInt64, cpu: UInt64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return (info.ri_phys_footprint, ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)))
    }
    private static let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()
    private static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return found > 0 ? Array(pids.prefix(Int(found))) : []
    }
}
