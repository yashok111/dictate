import Foundation
import CTranscriber
import Darwin

public struct ModelProfile: Codable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var peakBytes: UInt64
    public var rank: Int32
    public var automatic: Bool?
    public init(id: String, title: String, path: String, peakBytes: UInt64, rank: Int32, automatic: Bool? = nil) {
        self.id = id; self.title = title; self.path = path; self.peakBytes = peakBytes; self.rank = rank
        self.automatic = automatic
    }
    public func isEligible(for preference: String) -> Bool {
        preference == "auto" ? automatic != false : preference == id
    }
}

public enum MemoryPolicy {
    // Model budgets already include margin over measured worker peaks.
    // Keep an additional 500 MB available; pressure remains a separate gate.
    public static let reserveBytes: UInt64 = 500_000_000

    public static func choose(_ profiles: [ModelProfile], installed: [Bool], headroom: UInt64,
                              reserve: UInt64 = reserveBytes, pressure: Bool) -> Int? {
        guard profiles.count == installed.count else { return nil }
        let native = zip(profiles, installed).map {
            tr_profile(peak_bytes: $0.0.peakBytes, quality_rank: $0.0.rank, installed: $0.1 ? 1 : 0)
        }
        let index = native.withUnsafeBufferPointer {
            tr_select_profile($0.baseAddress, $0.count, headroom, reserve, pressure ? 1 : 0)
        }
        return index >= 0 ? Int(index) : nil
    }

    // Conservative development estimate. Pressure notifications are an independent
    // admission gate. This is not a reservation and needs qualification on 8 GB Macs.
    public static func headroom() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        guard status == KERN_SUCCESS, host_page_size(host, &page) == KERN_SUCCESS else { return 0 }
        return min(ProcessInfo.processInfo.physicalMemory,
                   (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(page))
    }
}
