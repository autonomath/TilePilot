import Darwin
import Foundation

enum ProcessMemoryDiagnostics {
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    static func formattedPhysicalFootprint() -> String {
        guard let bytes = physicalFootprintBytes() else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
