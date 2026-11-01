import AppKit
import SwiftUI

@MainActor
enum ScreenshotCapture {
    static func run(outputDir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let fileManager = FileManager.default
        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? fileManager.createDirectory(at: outURL, withIntermediateDirectories: true)

        let viewModel = DiskAuditViewModel()
        populateDemoData(viewModel)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1180, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)

        let tabs: [(NavigationTab, String)] = [
            (.smartOverview, "01_quick_clean.png"),
            (.safeCaches, "02_junk_and_temp_files.png"),
            (.projects, "03_old_coding_folders.png"),
            (.largeFiles, "04_big_files.png"),
            (.duplicates, "05_twin_files.png")
        ]

        for (tab, filename) in tabs {
            viewModel.selectedTab = tab
            let view = MainSplitView()
                .environmentObject(viewModel)
                .frame(width: 1180, height: 740)
                .preferredColorScheme(.dark)

            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 1180, height: 740)
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                continue
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                let dest = outURL.appendingPathComponent(filename)
                try? pngData.write(to: dest)
                print("Generated screenshot: \(dest.path)")
            }
        }
    }

    private static func populateDemoData(_ viewModel: DiskAuditViewModel) {
        viewModel.diskOverview = DiskOverview(
            totalBytes: 256 * 1024 * 1024 * 1024,
            availableBytes: 68 * 1024 * 1024 * 1024,
            usedBytes: 188 * 1024 * 1024 * 1024
        )

        let caches: [ScannedItem] = [
            ScannedItem(
                id: "c1",
                name: "com.apple.Safari",
                path: "~/Library/Caches/com.apple.Safari",
                physicalBytes: 1_420_000_000,
                logicalBytes: 1_420_000_000,
                category: "macOS App Caches",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 2,
                ecosystem: "macOS",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "c2",
                name: "Homebrew Caches",
                path: "~/Library/Caches/Homebrew",
                physicalBytes: 2_150_000_000,
                logicalBytes: 2_150_000_000,
                category: "Xcode & Homebrew Caches",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 14,
                ecosystem: "Homebrew",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "c3",
                name: "npm & Yarn Cache",
                path: "~/.npm/_cacache",
                physicalBytes: 890_000_000,
                logicalBytes: 890_000_000,
                category: "Web & Node Caches",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 38,
                ecosystem: "Node",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "c4",
                name: "Hugging Face Models Cache",
                path: "~/.cache/huggingface",
                physicalBytes: 3_400_000_000,
                logicalBytes: 3_400_000_000,
                category: "AI & Python Caches",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 21,
                ecosystem: "Python",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "c5",
                name: "Xcode DerivedData (Old Builds)",
                path: "~/Library/Developer/Xcode/DerivedData",
                physicalBytes: 4_600_000_000,
                logicalBytes: 4_600_000_000,
                category: "Xcode & Homebrew Caches",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 45,
                ecosystem: "Xcode",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            )
        ]
        viewModel.safeCacheItems = caches
        viewModel.categoryStatus[.safeCaches] = .completed(
            itemCount: caches.count,
            totalPhysicalBytes: caches.reduce(0) { $0 + $1.physicalBytes },
            timestamp: Date()
        )

        let projects: [ScannedItem] = [
            ScannedItem(
                id: "p1",
                name: "ecommerce-web (node_modules)",
                path: "~/Developer/ecommerce-web/node_modules",
                physicalBytes: 1_350_000_000,
                logicalBytes: 1_350_000_000,
                category: "Web & Node",
                risk: .rebuildable,
                activity: .stale,
                daysSinceModified: 84,
                ecosystem: "Web & Node",
                projectRoot: "~/Developer/ecommerce-web",
                restoreHint: "npm install",
                hasGit: true
            ),
            ScannedItem(
                id: "p2",
                name: "rust-ml-engine (target)",
                path: "~/Developer/rust-ml-engine/target",
                physicalBytes: 4_850_000_000,
                logicalBytes: 4_850_000_000,
                category: "Rust & Systems",
                risk: .rebuildable,
                activity: .stale,
                daysSinceModified: 62,
                ecosystem: "Rust & Systems",
                projectRoot: "~/Developer/rust-ml-engine",
                restoreHint: "cargo build",
                hasGit: true
            ),
            ScannedItem(
                id: "p3",
                name: "analytics-api (.venv)",
                path: "~/Developer/analytics-api/.venv",
                physicalBytes: 920_000_000,
                logicalBytes: 920_000_000,
                category: "Python & ML",
                risk: .rebuildable,
                activity: .stale,
                daysSinceModified: 110,
                ecosystem: "Python & ML",
                projectRoot: "~/Developer/analytics-api",
                restoreHint: "pip install -r requirements.txt",
                hasGit: true
            ),
            ScannedItem(
                id: "p4",
                name: "rustdisk (target)",
                path: "~/Documents/rustdisk/rust-core/target",
                physicalBytes: 810_000_000,
                logicalBytes: 810_000_000,
                category: "Rust & Systems",
                risk: .rebuildable,
                activity: .active,
                daysSinceModified: 0,
                ecosystem: "Rust & Systems",
                projectRoot: "~/Documents/rustdisk",
                restoreHint: "cargo build",
                hasGit: true
            )
        ]
        viewModel.projectItems = projects
        viewModel.categoryStatus[.projects] = .completed(
            itemCount: projects.count,
            totalPhysicalBytes: projects.reduce(0) { $0 + $1.physicalBytes },
            timestamp: Date()
        )

        let largeFiles: [ScannedItem] = [
            ScannedItem(
                id: "l1",
                name: "Xcode_15.4.xip",
                path: "~/Downloads/Xcode_15.4.xip",
                physicalBytes: 12_400_000_000,
                logicalBytes: 12_400_000_000,
                category: "Archives & Backups",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 140,
                ecosystem: "macOS",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "l2",
                name: "macOS_Sonoma_Installer.dmg",
                path: "~/Downloads/macOS_Sonoma_Installer.dmg",
                physicalBytes: 13_100_000_000,
                logicalBytes: 13_100_000_000,
                category: "Disk Images & Installers",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 95,
                ecosystem: "macOS",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "l3",
                name: "llama-3-8b-instruct.Q4_K_M.gguf",
                path: "~/Models/llama-3-8b-instruct.Q4_K_M.gguf",
                physicalBytes: 4_920_000_000,
                logicalBytes: 4_920_000_000,
                category: "AI Models & Datasets",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 28,
                ecosystem: "AI",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            ),
            ScannedItem(
                id: "l4",
                name: "wwdc24_keynote_4k.mp4",
                path: "~/Movies/wwdc24_keynote_4k.mp4",
                physicalBytes: 3_800_000_000,
                logicalBytes: 3_800_000_000,
                category: "Video & Audio Media",
                risk: .safe,
                activity: .stale,
                daysSinceModified: 120,
                ecosystem: "Media",
                projectRoot: "",
                restoreHint: "",
                hasGit: false
            )
        ]
        viewModel.largeFileItems = largeFiles
        viewModel.categoryStatus[.largeFiles] = .completed(
            itemCount: largeFiles.count,
            totalPhysicalBytes: largeFiles.reduce(0) { $0 + $1.physicalBytes },
            timestamp: Date()
        )

        let duplicates: [DuplicateGroup] = [
            DuplicateGroup(
                id: "d1",
                title: "2 Identical Files: dataset_v2_final.parquet",
                subtitle: "Identical content (3.2 GB each) · BLAKE3 verified",
                kind: .duplicateFile,
                category: "AI Models & Datasets",
                singleItemBytes: 3_200_000_000,
                reclaimablePhysicalBytes: 3_200_000_000,
                members: [
                    DuplicateMember(
                        id: "m1",
                        name: "dataset_v2_final.parquet",
                        path: "~/Datasets/dataset_v2_final.parquet",
                        physicalBytes: 3_200_000_000,
                        logicalBytes: 3_200_000_000,
                        daysSinceModified: 45,
                        isKeepRecommended: true,
                        sourceLabel: "Original Copy"
                    ),
                    DuplicateMember(
                        id: "m2",
                        name: "dataset_v2_final (1).parquet",
                        path: "~/Downloads/dataset_v2_final (1).parquet",
                        physicalBytes: 3_200_000_000,
                        logicalBytes: 3_200_000_000,
                        daysSinceModified: 12,
                        isKeepRecommended: false,
                        sourceLabel: "Redundant Copy"
                    )
                ]
            ),
            DuplicateGroup(
                id: "d2",
                title: "2 Identical Installers: Docker.dmg",
                subtitle: "Identical disk image installer · 8-point stride fingerprint",
                kind: .duplicateFile,
                category: "Disk Images & Installers",
                singleItemBytes: 680_000_000,
                reclaimablePhysicalBytes: 680_000_000,
                members: [
                    DuplicateMember(
                        id: "m3",
                        name: "Docker.dmg",
                        path: "~/Applications/Installers/Docker.dmg",
                        physicalBytes: 680_000_000,
                        logicalBytes: 680_000_000,
                        daysSinceModified: 90,
                        isKeepRecommended: true,
                        sourceLabel: "Original Copy"
                    ),
                    DuplicateMember(
                        id: "m4",
                        name: "Docker (1).dmg",
                        path: "~/Downloads/Docker (1).dmg",
                        physicalBytes: 680_000_000,
                        logicalBytes: 680_000_000,
                        daysSinceModified: 30,
                        isKeepRecommended: false,
                        sourceLabel: "Redundant Copy"
                    )
                ]
            )
        ]
        viewModel.duplicateGroups = duplicates
        viewModel.categoryStatus[.duplicates] = .completed(
            itemCount: duplicates.count,
            totalPhysicalBytes: duplicates.reduce(0) { $0 + $1.reclaimablePhysicalBytes },
            timestamp: Date()
        )

        let packages: [TerminalPackage] = [
            TerminalPackage(
                id: "k1",
                name: "node@18",
                manager: "Homebrew Formula",
                path: "/opt/homebrew/Cellar/node@18/18.20.2",
                physicalBytes: 120_000_000,
                logicalBytes: 120_000_000,
                versionCount: 1,
                installedOnRequest: true,
                risk: .safe,
                uninstallCmd: "brew uninstall node@18"
            ),
            TerminalPackage(
                id: "k2",
                name: "Docker.raw",
                manager: "Container VM",
                path: "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                physicalBytes: 4_500_000_000,
                logicalBytes: 64_000_000_000,
                versionCount: 1,
                installedOnRequest: true,
                risk: .highRiskCli,
                uninstallCmd: "docker system prune -a --volumes"
            )
        ]
        viewModel.terminalPackages = packages
        viewModel.categoryStatus[.packages] = .completed(
            itemCount: packages.count,
            totalPhysicalBytes: packages.reduce(0) { $0 + $1.physicalBytes },
            timestamp: Date()
        )

        viewModel.selectedIDs = Set([
            "c1", "c2", "c3", "c5",
            "p1", "p2", "p3",
            "l2",
            "m2", "m4"
        ])
    }
}
