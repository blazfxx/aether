import Foundation
import IOKit
import IOKit.ps
import Darwin

public struct MemoryStats: Sendable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var used: UInt64 { app + wired + compressed }
    public var pressure: Double { total == 0 ? 0 : Double(used) / Double(total) }
    public init() {}
}

public struct DiskStats: Sendable {
    public var total: Int64 = 0
    /// "Available" as Finder reports it: free space plus purgeable space.
    public var available: Int64 = 0
    public var used: Int64 { total - available }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    public init(total: Int64 = 0, available: Int64 = 0) { self.total = total; self.available = available }
}

public struct BatteryStats: Sendable {
    public var percent: Int = 0
    public var isCharging = false
    public var onAC = false
    public var cycleCount: Int?
    /// Max capacity relative to design capacity, 0...100.
    public var healthPercent: Int?
    public var temperatureC: Double?
    public var minutesRemaining: Int?
    public init() {}
}

public struct ProcessStat: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let rssBytes: UInt64
}

public struct SystemSnapshot: Sendable {
    public var cpuPerCore: [Double] = []
    public var cpuTotal: Double { cpuPerCore.isEmpty ? 0 : cpuPerCore.reduce(0, +) / Double(cpuPerCore.count) }
    public var memory = MemoryStats()
    public var disk = DiskStats()
    public var battery: BatteryStats?
    public var uptime: TimeInterval = 0
    public var thermal: ProcessInfo.ThermalState = .nominal
    public var netDownBps: Double = 0
    public var netUpBps: Double = 0
    public init() {}
}

public final class SystemSampler: @unchecked Sendable {
    private var lastTicks: [[UInt32]]?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    public init() {}

    public func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpuPerCore = cpu()
        s.memory = memory()
        s.disk = Self.disk()
        s.battery = Self.battery()
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.thermal = ProcessInfo.processInfo.thermalState
        let (d, u) = network()
        s.netDownBps = d; s.netUpBps = u
        return s
    }

    // MARK: CPU

    private func cpu() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var now: [[UInt32]] = []
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            now.append([UInt32(info[base + Int(CPU_STATE_USER)]), UInt32(info[base + Int(CPU_STATE_SYSTEM)]),
                        UInt32(info[base + Int(CPU_STATE_IDLE)]), UInt32(info[base + Int(CPU_STATE_NICE)])])
        }
        defer { lastTicks = now }
        guard let prev = lastTicks, prev.count == now.count else { return Array(repeating: 0, count: now.count) }
        return zip(now, prev).map { n, p in
            let user = Double(n[0] &- p[0]), sys = Double(n[1] &- p[1]), idle = Double(n[2] &- p[2]), nice = Double(n[3] &- p[3])
            let total = user + sys + idle + nice
            return total > 0 ? (user + sys + nice) / total : 0
        }
    }

    // MARK: Memory

    private func memory() -> MemoryStats {
        var m = MemoryStats()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return m }
        let page = UInt64(vm_kernel_page_size)
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page
        // Activity Monitor: App Memory = internal pages - purgeable.
        m.app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page
        m.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        m.free = UInt64(stats.free_count) * page
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        return m
    }

    // MARK: Disk

    public static func disk() -> DiskStats {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return DiskStats() }
        return DiskStats(total: Int64(v.volumeTotalCapacity ?? 0), available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Battery

    public static func battery() -> BatteryStats? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any],
              (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        else { return nil }
        var b = BatteryStats()
        b.percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        b.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        b.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let t = desc[kIOPSTimeToEmptyKey] as? Int
        b.minutesRemaining = (t ?? -1) > 0 ? t : nil

        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                b.cycleCount = d["CycleCount"] as? Int
                // AppleRawMaxCapacity / DesignCapacity are in mAh on Apple silicon.
                let maxCap = (d["AppleRawMaxCapacity"] as? Int) ?? (d["MaxCapacity"] as? Int)
                if let design = d["DesignCapacity"] as? Int, let maxCap, design > 0, maxCap > 100 {
                    b.healthPercent = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
                }
                if let t = d["Temperature"] as? Int { b.temperatureC = Double(t) / 100 }
            }
        }
        return b
    }

    // MARK: Network

    private func network() -> (down: Double, up: Double) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
               let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes); tx += UInt64(data.pointee.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        let now = Date()
        defer { lastNet = (rx, tx, now) }
        guard let last = lastNet else { return (0, 0) }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0, rx >= last.rx, tx >= last.tx else { return (0, 0) }
        return (Double(rx - last.rx) / dt, Double(tx - last.tx) / dt)
    }

    // MARK: Processes

    /// Top processes by resident memory, via `ps`.
    public static func topProcesses(limit: Int = 8) -> [ProcessStat] {
        guard let out = run("/bin/ps", ["-Ax", "-o", "pid=,pcpu=,rss=,comm="]) else { return [] }
        var all: [ProcessStat] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { continue }
            let path = String(parts[3])
            var name = (path as NSString).lastPathComponent
            if let r = path.range(of: ".app/") { name = ((String(path[..<r.lowerBound]) + ".app") as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
            all.append(ProcessStat(pid: pid, name: name, cpu: cpu, rssBytes: rss * 1024))
        }
        // Collapse helper processes into their parent app.
        var merged: [String: ProcessStat] = [:]
        for p in all {
            if let e = merged[p.name] {
                merged[p.name] = ProcessStat(pid: e.rssBytes >= p.rssBytes ? e.pid : p.pid, name: p.name, cpu: e.cpu + p.cpu, rssBytes: e.rssBytes + p.rssBytes)
            } else { merged[p.name] = p }
        }
        return Array(merged.values.sorted { $0.rssBytes > $1.rssBytes }.prefix(limit))
    }
}
