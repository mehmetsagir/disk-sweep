import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - CPU

public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPULoad {
    /// Busy share (0...1) between two tick snapshots. Counters wrap, so subtraction wraps too.
    public static func fraction(from previous: CPUTicks, to current: CPUTicks) -> Double {
        let busy = UInt64(current.user &- previous.user)
            + UInt64(current.system &- previous.system)
            + UInt64(current.nice &- previous.nice)
        let idle = UInt64(current.idle &- previous.idle)
        let total = busy + idle
        return total == 0 ? 0 : Double(busy) / Double(total)
    }
}

public struct CPUReading: Sendable {
    public var total: Double
    public var user: Double
    public var system: Double
    public var idle: Double
    public var cores: [Double]

    public static let zero = CPUReading(total: 0, user: 0, system: 0, idle: 1, cores: [])
}

public final class CPUSampler {
    private var previous: [CPUTicks] = []

    public init() {}

    /// Overall and per-core load since the previous call (0...1). The first call returns zeros.
    public func sample() -> CPUReading {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return .zero }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var current: [CPUTicks] = []
        for core in 0..<Int(coreCount) {
            let base = Int(CPU_STATE_MAX) * core
            current.append(CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        defer { previous = current }
        guard previous.count == current.count else {
            return CPUReading(total: 0, user: 0, system: 0, idle: 1, cores: Array(repeating: 0, count: current.count))
        }

        var userTicks: UInt64 = 0, systemTicks: UInt64 = 0, idleTicks: UInt64 = 0
        for (old, new) in zip(previous, current) {
            userTicks += UInt64(new.user &- old.user) + UInt64(new.nice &- old.nice)
            systemTicks += UInt64(new.system &- old.system)
            idleTicks += UInt64(new.idle &- old.idle)
        }
        let all = Double(userTicks + systemTicks + idleTicks)
        let cores = zip(previous, current).map { CPULoad.fraction(from: $0, to: $1) }
        guard all > 0 else { return CPUReading(total: 0, user: 0, system: 0, idle: 1, cores: cores) }
        let user = Double(userTicks) / all
        let system = Double(systemTicks) / all
        return CPUReading(total: user + system, user: user, system: system, idle: Double(idleTicks) / all, cores: cores)
    }
}

// MARK: - Static machine info

public struct SystemInfo: Sendable {
    public var cpuModel: String
    public var logicalCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?

    public static func read() -> SystemInfo {
        SystemInfo(
            cpuModel: sysctlString("machdep.cpu.brand_string") ?? L("Bilinmeyen işlemci"),
            logicalCores: ProcessInfo.processInfo.processorCount,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"))
    }

    /// 1, 5 and 15 minute load averages.
    public static func loadAverage() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    public static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

// MARK: - Memory

public enum MemoryPressure: Sendable {
    case normal, warning, critical
}

public struct MemoryStats: Sendable {
    public var used: UInt64
    public var total: UInt64
    public var pressure: MemoryPressure
    /// Activity Monitor style breakdown; app + wired + compressed == used.
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    /// File-backed and purgeable pages the system can drop on demand.
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0

    public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public enum MemoryReader {
    /// "Used" follows Activity Monitor: app memory + wired + compressed.
    public static func read() -> MemoryStats {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryStats(used: 0, total: total, pressure: .normal) }

        let page = UInt64(getpagesize())
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = min(app + wired + compressed, total)
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        let free = total > used + cached ? total - used - cached : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemoryStats(used: used, total: total, pressure: pressure(), app: app, wired: wired,
                           compressed: compressed, cached: min(cached, total), free: free,
                           swapUsed: hasSwap ? swap.xsu_used : 0, swapTotal: hasSwap ? swap.xsu_total : 0)
    }

    private static func pressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

// MARK: - Processes

public struct ProcessUsage: Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Percent of one core, as reported by `ps` (can exceed 100 for multi-threaded work).
    public var cpu: Double
    /// Resident memory in bytes.
    public var memory: UInt64

    public var id: Int32 { pid }
}

public enum ProcessLister {
    public static func snapshot() async -> [ProcessUsage] {
        let result = await Shell.run(executable: "/bin/ps", arguments: ["-A", "-c", "-o", "pid=,pcpu=,rss=,comm="], timeout: 10)
        return result.succeeded ? parse(result.stdout) : []
    }

    /// Parses `pid pcpu rss comm` lines; the command name may contain spaces.
    public static func parse(_ output: String) -> [ProcessUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rssKilobytes = UInt64(parts[2]) else { return nil }
            return ProcessUsage(pid: pid, name: String(parts[3]).trimmingCharacters(in: .whitespaces),
                                cpu: cpu, memory: rssKilobytes * 1024)
        }
    }
}

// MARK: - Disk

public struct VolumeInfo: Sendable, Identifiable {
    public var name: String
    public var path: String
    public var total: Int64
    public var available: Int64
    public var isInternal: Bool
    /// Mounted disk images and installers: free space is meaningless there.
    public var isReadOnly: Bool

    public var id: String { path }
    public var used: Int64 { total - available }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public enum VolumeReader {
    /// Mounted, browsable volumes (the system's hidden helper volumes are skipped).
    public static func list() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeInfo(name: values.volumeName ?? url.lastPathComponent, path: url.path,
                              total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0,
                              isInternal: values.volumeIsInternal ?? true,
                              isReadOnly: values.volumeIsReadOnly ?? false)
        }
    }
}

/// Disk throughput from the block storage drivers' cumulative byte counters.
public final class DiskIOSampler {
    private var previous: (read: UInt64, written: UInt64, time: Date)?

    public init() {}

    public func sample(now: Date = Date()) -> (read: Double, write: Double) {
        let counters = Self.counters()
        defer { previous = (counters.read, counters.written, now) }
        guard let previous else { return (0, 0) }
        let seconds = now.timeIntervalSince(previous.time)
        guard seconds > 0 else { return (0, 0) }
        return (Double(counters.read &- previous.read) / seconds, Double(counters.written &- previous.written) / seconds)
    }

    static func counters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, written: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let statistics = dictionary["Statistics"] as? [String: Any] {
                read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (read, written)
    }
}

// MARK: - Network

public struct NetworkInterface: Sendable, Identifiable {
    public var name: String
    public var ipv4: String?
    public var down: Double
    public var up: Double

    public var id: String { name }
}

public struct NetworkReading: Sendable {
    public var down: Double
    public var up: Double
    public var interfaces: [NetworkInterface]
}

public final class NetworkSampler {
    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastTime: Date?

    public init() {}

    /// Bytes per second since the previous call, summed over physical interfaces (en*).
    public func sample(now: Date = Date()) -> (down: Double, up: Double) {
        let reading = sampleDetailed(now: now)
        return (reading.down, reading.up)
    }

    public func sampleDetailed(now: Date = Date()) -> NetworkReading {
        let counters = Self.counters()
        let before = previous
        let beforeTime = lastTime
        previous = counters
        lastTime = now

        let addresses = Self.ipv4Addresses()
        guard let beforeTime, now.timeIntervalSince(beforeTime) > 0 else {
            return NetworkReading(down: 0, up: 0, interfaces: [])
        }
        let seconds = now.timeIntervalSince(beforeTime)

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces: [NetworkInterface] = []
        for (name, current) in counters {
            guard let old = before[name] else { continue }
            let rx = UInt64(Self.delta(from: old.rx, to: current.rx))
            let tx = UInt64(Self.delta(from: old.tx, to: current.tx))
            received += rx
            sent += tx
            if addresses[name] != nil || rx > 0 || tx > 0 {
                interfaces.append(NetworkInterface(name: name, ipv4: addresses[name],
                                                   down: Double(rx) / seconds, up: Double(tx) / seconds))
            }
        }
        interfaces.sort { $0.name < $1.name }
        return NetworkReading(down: Double(received) / seconds, up: Double(sent) / seconds, interfaces: interfaces)
    }

    /// The kernel exposes 32-bit counters, which wrap; unsigned wrapping subtraction handles it.
    public static func delta(from old: UInt32, to new: UInt32) -> UInt32 { new &- old }

    static func counters() -> [String: (rx: UInt32, tx: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let raw = pointer.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        return result
    }

    static func ipv4Addresses() -> [String: String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result[name] = String(cString: host)
            }
        }
        return result
    }
}

// MARK: - Battery

public struct BatteryStatus: Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var onACPower: Bool
    public var minutesRemaining: Int?
}

public enum BatteryReader {
    /// `nil` on Macs without an internal battery.
    public static func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }

            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            return BatteryStatus(percent: current * 100 / maximum, isCharging: charging, onACPower: onAC,
                                 minutesRemaining: (minutes ?? -1) >= 0 ? minutes : nil)
        }
        return nil
    }
}

// MARK: - Formatting

extension Format {
    /// "3 gün 4 sa", "5 sa 12 dk", "12 dk".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return L("\(days) gün \(hours) sa") }
        if hours > 0 { return L("\(hours) sa \(minutes) dk") }
        return L("\(minutes) dk")
    }

    /// "1,2 MB/s"
    public static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file) + "/s"
    }

    /// Short form for the menu bar: "0K", "340K", "1.2M".
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1e9 { return String(format: "%.1fG", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if value >= 1e3 { return String(format: "%.0fK", value / 1e3) }
        return "0K"
    }
}
