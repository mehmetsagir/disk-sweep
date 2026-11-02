import XCTest
@testable import DiskSweepCore

final class SystemStatsTests: XCTestCase {
    func testCPUFractionFromTickDeltas() {
        let before = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CPUTicks(user: 160, system: 70, idle: 920, nice: 0)  // +60 +20 busy, +70 idle
        XCTAssertEqual(CPULoad.fraction(from: before, to: after), 80.0 / 150.0, accuracy: 0.0001)
    }

    func testCPUFractionSurvivesCounterWrap() {
        let before = CPUTicks(user: UInt32.max - 5, system: 0, idle: 0, nice: 0)
        let after = CPUTicks(user: 4, system: 0, idle: 10, nice: 0)  // wrapped: +10 busy, +10 idle
        XCTAssertEqual(CPULoad.fraction(from: before, to: after), 0.5, accuracy: 0.0001)
    }

    func testCPUFractionWithNoElapsedTicksIsZero() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertEqual(CPULoad.fraction(from: ticks, to: ticks), 0)
    }

    func testNetworkCounterWrapDelta() {
        XCTAssertEqual(NetworkSampler.delta(from: 100, to: 250), 150)
        XCTAssertEqual(NetworkSampler.delta(from: UInt32.max - 9, to: 5), 15)
    }

    func testRateFormatting() {
        XCTAssertEqual(Format.compactRate(0), "0K")
        XCTAssertEqual(Format.compactRate(-5), "0K")
        XCTAssertEqual(Format.compactRate(340_000), "340K")
        XCTAssertEqual(Format.compactRate(1_234_000), "1.2M")
        XCTAssertEqual(Format.compactRate(2_500_000_000), "2.5G")
    }

    func testLiveSamplersReturnSaneValues() {
        let memory = MemoryReader.read()
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)

        let cpu = CPUSampler()
        _ = cpu.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let reading = cpu.sample()
        XCTAssertFalse(reading.cores.isEmpty)
        XCTAssertTrue((0...1).contains(reading.total))

        let network = NetworkSampler()
        _ = network.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let rates = network.sample()
        XCTAssertGreaterThanOrEqual(rates.down, 0)
        XCTAssertGreaterThanOrEqual(rates.up, 0)
    }

    func testProcessListParsing() {
        let output = """
          1   0,0  13312 launchd
        412  12.5 204800 Google Chrome Helper
         77 101.9   9000 kernel_task
        bad line
        """
        let processes = ProcessLister.parse(output)
        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[1].name, "Google Chrome Helper")
        XCTAssertEqual(processes[1].cpu, 12.5, accuracy: 0.001)
        XCTAssertEqual(processes[1].memory, 204_800 * 1024)
        XCTAssertEqual(processes[2].cpu, 101.9, accuracy: 0.001)
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(30), "0 dk")
        XCTAssertEqual(Format.duration(12 * 60), "12 dk")
        XCTAssertEqual(Format.duration(5 * 3600 + 12 * 60), "5 sa 12 dk")
        XCTAssertEqual(Format.duration(3 * 86_400 + 4 * 3600), "3 gün 4 sa")
    }

    func testMemoryBreakdownIsConsistent() {
        let memory = MemoryReader.read()
        XCTAssertEqual(memory.app + memory.wired + memory.compressed >= memory.used, true)
        XCTAssertLessThanOrEqual(memory.used + memory.cached + memory.free, memory.total + memory.total / 100)
        XCTAssertGreaterThan(memory.app, 0)
        XCTAssertGreaterThan(memory.wired, 0)
    }

    func testCPUBreakdownAddsUp() {
        let sampler = CPUSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let reading = sampler.sample()
        XCTAssertEqual(reading.user + reading.system + reading.idle, 1, accuracy: 0.001)
        XCTAssertEqual(reading.total, reading.user + reading.system, accuracy: 0.001)
    }

    func testSystemInfoAndVolumes() {
        let info = SystemInfo.read()
        XCTAssertFalse(info.cpuModel.isEmpty)
        XCTAssertGreaterThan(info.logicalCores, 0)
        XCTAssertGreaterThan(SystemInfo.uptime, 0)
        XCTAssertFalse(VolumeReader.list().isEmpty)
        XCTAssertEqual(SystemInfo.loadAverage().one >= 0, true)
    }

    func testDetailedNetworkReadingDoesNotCrash() {
        let network = NetworkSampler()
        _ = network.sampleDetailed()
        Thread.sleep(forTimeInterval: 0.2)
        let reading = network.sampleDetailed()
        XCTAssertGreaterThanOrEqual(reading.down, 0)
        XCTAssertEqual(reading.interfaces.allSatisfy { $0.name.hasPrefix("en") }, true)
    }
}
