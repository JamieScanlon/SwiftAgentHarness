//
//  PID + start-time token for transcript lock staleness (harness README; Linux /proc vs Darwin sysctl).
//

import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum ProcessLockIdentity: Sendable {
    static func currentBootKey() -> String {
        #if os(Linux)
        let path = "/proc/sys/kernel/random/boot_id"
        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "unknown_boot"
        #elseif canImport(Darwin)
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var len = size_t(MemoryLayout.size(ofValue: boot))
        let rc = sysctl(&name, 2, &boot, &len, nil, 0)
        if rc == 0 {
            return "\(boot.tv_sec)_\(boot.tv_usec)"
        }
        return "unknown_boot"
        #else
        return "unknown_boot"
        #endif
    }

    /// Stable per-process start key for `pid` (README `starttime`; detects PID recycle).
    static func startToken(for pid: pid_t) -> UInt64 {
        guard pid > 0 else { return 0 }
        #if os(Linux)
        linuxStartTimeTicks(pid: pid)
        #elseif canImport(Darwin)
        return darwinStartToken(pid: pid)
        #else
        return 0
        #endif
    }

    static func isPidAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    #if os(Linux)
    private static func linuxStartTimeTicks(pid: pid_t) -> UInt64 {
        let path = "/proc/\(Int(pid))/stat"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        guard let close = raw.lastIndex(of: ")") else { return 0 }
        let tail = raw[raw.index(after: close)...]
        let parts = tail.split(whereSeparator: { $0 == " " }).map(String.init)
        guard parts.count > 19, let st = UInt64(parts[19]) else { return 0 }
        return st
    }
    #elseif canImport(Darwin)
    private static func darwinStartToken(pid: pid_t) -> UInt64 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let err = sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0)
        guard err == 0 else { return 0 }
        let tv = kp.kp_proc.p_starttime
        return UInt64(bitPattern: Int64(tv.tv_sec)) &* 1_000_000 &+ UInt64(bitPattern: Int64(tv.tv_usec))
    }
    #endif
}
