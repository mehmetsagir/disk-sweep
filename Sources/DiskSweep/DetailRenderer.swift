import SwiftUI

/// Test helper: renders the panels off-screen so they can be inspected without clicking anything.
@MainActor
enum DetailRenderer {
    static func renderAll(into directory: URL, monitor: SystemMonitor) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let noop: () -> Void = {}
        write(CPUDetail(monitor: monitor, openMainWindow: noop), "cpu", directory)
        write(MemoryDetail(monitor: monitor, openMainWindow: noop), "memory", directory)
        write(DiskDetail(monitor: monitor, openMainWindow: noop), "disk", directory)
        write(NetworkDetail(monitor: monitor, openMainWindow: noop), "network", directory)
        write(SystemPopover(monitor: monitor, openMainWindow: noop), "overview", directory)
    }

    private static func write<V: View>(_ view: V, _ name: String, _ directory: URL) {
        let framed = view
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
