import Foundation
import MachO

// MARK: - App Memory Usage

/// Samples the current process's resident memory using the Mach task VM info interface.
///
/// This is the same technique used by Xcode's memory gauge and `os_proc_available_memory`.
/// It requires no special entitlements and works on iOS and macOS.
public enum AppMemoryUsage {

    /// Returns the number of bytes of physical memory currently attributed to this process,
    /// or `nil` if the Mach kernel call fails (extremely unlikely in practice).
    public static func currentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // `phys_footprint` is the memory that counts against the app's memory limit —
        // it matches what Xcode's memory gauge shows.
        return info.phys_footprint
    }

    /// Formats a byte count as a compact human-readable string, e.g. "412 MB" or "1.2 GB".
    public static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
