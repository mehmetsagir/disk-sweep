import SwiftUI
import DiskSweepCore

/// Samples CPU, memory, disk, network and battery every couple of seconds.
@MainActor @Observable
final class SystemMonitor {
    static let historyLength = 40
    static let shared = SystemMonitor()

    let info = SystemInfo.read()

    // CPU
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuIdle: Double = 1
    var cores: [Double] = []
    var load = SystemInfo.loadAverage()
    var uptime = SystemInfo.uptime

    // GPU
    var gpu: Double? = GPUReader.read()

    // Memory
    var memory = MemoryReader.read()

    // Disk
    var disk = DiskUsage.current()
    var volumes = VolumeReader.list()
    var diskRead: Double = 0
    var diskWrite: Double = 0

    // Network
    var download: Double = 0
    var upload: Double = 0
    var interfaces: [NetworkInterface] = []
    var sessionDownloaded: Double = 0
    var sessionUploaded: Double = 0

    var battery: BatteryStatus? = BatteryReader.read()

    // Histories for the graphs
    // Pre-filled so graphs span their full width from the first second.
    var cpuHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)
    var gpuHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)
    var memoryHistory = [Double](repeating: MemoryReader.read().fraction, count: SystemMonitor.historyLength)
    var downloadHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)
    var uploadHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)
    var diskReadHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)
    var diskWriteHistory = [Double](repeating: 0, count: SystemMonitor.historyLength)

    // Busiest processes; only refreshed while a detail popover is open (running `ps` is not free).
    var topCPU: [ProcessUsage] = []
    var topMemory: [ProcessUsage] = []

    @ObservationIgnored var detailActive = false {
        didSet { if detailActive { refreshProcesses() } }
    }

    @ObservationIgnored private let cpuSampler = CPUSampler()
    @ObservationIgnored private let networkSampler = NetworkSampler()
    @ObservationIgnored private let diskSampler = DiskIOSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSample = Date()
    @ObservationIgnored private var refreshingProcesses = false
    @ObservationIgnored private var tick = 0
    @ObservationIgnored var onUpdate: (() -> Void)?

    init() {
        // Prime the delta-based samplers so the first visible values are real.
        _ = cpuSampler.sample()
        _ = networkSampler.sampleDetailed()
        _ = diskSampler.sample()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppSettings.sampleSeconds))
                self?.sample()
            }
        }
    }

    private func sample() {
        tick += 1
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastSample), 0)
        lastSample = now

        let processor = cpuSampler.sample()
        let graphics = GPUReader.read()
        let network = networkSampler.sampleDetailed(now: now)
        let storage = diskSampler.sample(now: now)

        // Animate only while a detail popover is visible; otherwise every tick would re-diff all views.
        withAnimation(detailActive ? Motion.smooth : nil) {
            cpu = processor.total
            cpuUser = processor.user
            cpuSystem = processor.system
            cpuIdle = processor.idle
            cores = processor.cores
            load = SystemInfo.loadAverage()
            uptime = SystemInfo.uptime
            gpu = graphics

            memory = MemoryReader.read()

            // Free space and mounted volumes change slowly and cost a few ms each to read.
            if tick % 5 == 0 || detailActive {
                disk = DiskUsage.current()
                volumes = VolumeReader.list()
            }
            diskRead = storage.read
            diskWrite = storage.write

            download = network.down
            upload = network.up
            interfaces = network.interfaces
            sessionDownloaded += network.down * elapsed
            sessionUploaded += network.up * elapsed

            battery = BatteryReader.read()

            push(&cpuHistory, processor.total)
            if let graphics { push(&gpuHistory, graphics) }
            push(&memoryHistory, memory.fraction)
            push(&downloadHistory, network.down)
            push(&uploadHistory, network.up)
            push(&diskReadHistory, storage.read)
            push(&diskWriteHistory, storage.write)
        }
        if detailActive { refreshProcesses() }
        onUpdate?()
    }

    private func refreshProcesses() {
        guard !refreshingProcesses else { return }
        refreshingProcesses = true
        Task { [weak self] in
            let all = await ProcessLister.snapshot()
            guard let self else { return }
            let candidates = all.filter { $0.name != "ps" }
            self.topCPU = Array(candidates.sorted { $0.cpu > $1.cpu }.prefix(5))
            self.topMemory = Array(candidates.sorted { $0.memory > $1.memory }.prefix(5))
            self.refreshingProcesses = false
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// Which readings appear in the menu bar itself, and whether they carry a mini graph.
enum MenuBarKey {
    static let cpu = MenuBarMetric.cpu.storageKey
    static let gpu = MenuBarMetric.gpu.storageKey
    static let memory = MenuBarMetric.memory.storageKey
    static let disk = MenuBarMetric.disk.storageKey
    static let network = MenuBarMetric.network.storageKey
    static let graphs = "menubar.graphs"

    static var graphsEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: graphs) == nil ? true : defaults.bool(forKey: graphs)
    }
}
