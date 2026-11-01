import SwiftUI

@main
struct RustDiskApp: App {
    @StateObject private var viewModel = DiskAuditViewModel()

    init() {
        if CommandLine.arguments.contains("--capture-screenshots") {
            ScreenshotCapture.run(outputDir: "docs/images")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("RustDisk") {
            MainSplitView()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Scan Now") {
                    viewModel.runScan()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Select Recommended") {
                    viewModel.resetToRecommended()
                }
                .keyboardShortcut("a", modifiers: [.command])

                Button("Deselect All") {
                    viewModel.selectedIDs.removeAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Clean Selected") {
                    viewModel.requestCleanup()
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Divider()

                Button("Smart Overview") { viewModel.selectedTab = .smartOverview }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Safe Caches") { viewModel.selectedTab = .safeCaches }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Project Dependencies") { viewModel.selectedTab = .projects }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Terminal Packages") { viewModel.selectedTab = .packages }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Large File Finder") { viewModel.selectedTab = .largeFiles }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("Duplicates") { viewModel.selectedTab = .duplicates }
                    .keyboardShortcut("6", modifiers: [.command])
            }
        }
    }
}
