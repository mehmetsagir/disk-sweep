import SwiftUI

@main
struct DiskSweepApp: App {
    var body: some Scene {
        WindowGroup("DiskSweep") {
            ContentView()
                .frame(minWidth: 960, idealWidth: 1100, maxWidth: .infinity,
                       minHeight: 620, idealHeight: 760, maxHeight: .infinity)
        }
        .defaultSize(width: 1100, height: 760)
    }
}
