import Foundation
import Darwin
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]),
      let duration = Double(CommandLine.arguments[2]), duration > 0, duration <= 10800 else {
    fputs("usage: process-sample PID SECONDS (up to 10800)\n", stderr); exit(2)
}
var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
let end = ProcessInfo.processInfo.systemUptime + duration
while ProcessInfo.processInfo.systemUptime < end {
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    if status != 0 { break }
    let row: [String: Any] = ["unix": Date().timeIntervalSince1970, "pid": pid, "cpu_ticks": info.ri_user_time + info.ri_system_time,
        "mach_timebase_numer": timebase.numer, "mach_timebase_denom": timebase.denom,
        "energy_nj": info.ri_energy_nj, "interrupt_wakeups": info.ri_interrupt_wkups,
        "idle_wakeups": info.ri_pkg_idle_wkups, "footprint_bytes": info.ri_phys_footprint,
        "disk_write_bytes": info.ri_diskio_byteswritten]
    print(String(data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!); fflush(stdout)
    Thread.sleep(forTimeInterval: 1)
}
