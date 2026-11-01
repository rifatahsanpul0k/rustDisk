import Foundation
import AppKit
import SwiftUI

enum CategoryScanStatus: Equatable {
    case notScanned
    case scanning
    case completed(itemCount: Int, totalPhysicalBytes: UInt64, timestamp: Date)
    case cancelled

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

@MainActor
final class DiskAuditViewModel: ObservableObject {
    @Published var safeCacheItems: [ScannedItem] = []
    @Published var projectItems: [ScannedItem] = []
    @Published var largeFileItems: [ScannedItem] = []
    @Published var terminalPackages: [TerminalPackage] = []
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var selectedIDs = Set<String>()
    @Published var selectedTab: NavigationTab = .smartOverview
    @Published var deletionMode: DeletionMode = .moveToTrash
    @Published var largeFileThresholdBytes: UInt64 = 500 * 1024 * 1024
    @Published var duplicateMinSizeBytes: UInt64 = 1 * 1024 * 1024
    @Published var hideLargeFileDevCaches = true
    @Published var staleThresholdDays: UInt64 = 30
    @Published var categoryStatus: [NavigationTab: CategoryScanStatus] = [
        .safeCaches: .notScanned,
        .projects: .notScanned,
        .largeFiles: .notScanned,
        .duplicates: .notScanned,
        .packages: .notScanned,
    ]
    @Published var activeScanningCategory: NavigationTab?
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var statusBanner = "Ready to audit your Mac"
    @Published var scanPhase = "Ready to audit your Mac"
    @Published var scanPhaseDetail = "Waiting to start"
    @Published var scanPhaseIndex = 0
    @Published var scanProgress = 0.0
    @Published var scanDiscoveredBytes: UInt64 = 0
    @Published var diskOverview: DiskOverview?
    @Published var showingPermanentDeleteConfirmation = false
    @Published var pendingPackageAction: TerminalPackage?
    @Published var showingPackageActionConfirmation = false
    @Published var pendingMaintenanceAction: String?
    @Published var showingMaintenanceConfirmation = false
    @Published var showingSafetyGuide = false
    @Published var showingDiagnosticDetails = false
    @Published var diagnosticSkippedPaths: [String] = []
    @Published var diagnosticMessage: String?
    @Published var showingOpenTrashAction = false
    @Published var smartCleanIncludeCaches = true
    @Published var smartCleanIncludeStaleProjects = true
    @Published var smartCleanIncludeInstallers = true
    @Published var smartCleanIncludeTerminalPackages = false
    @Published var allowDeleteAllDuplicateCopies = false
    @Published var unlockActiveProjectSelection = false
    @Published var thermalStateLabel: String?
    @Published var showProDetails: Bool = UserDefaults.standard.bool(forKey: "showProDetails") {
        didSet {
            UserDefaults.standard.set(showProDetails, forKey: "showProDetails")
        }
    }

    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private var activeScanTask: Task<Void, Never>?

    var scanPercentText: String {
        "\(Int((scanProgress * 100).rounded()))%"
    }

    init() {
        diskOverview = getDiskOverview()
        updateThermalState()
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateThermalState()
            }
        }
    }

    func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        let level: UInt8
        let label: String?
        switch state {
        case .nominal:
            level = 0
            label = nil
        case .fair:
            level = 1
            label = "Cool & Quiet Mode"
        case .serious, .critical:
            level = state == .serious ? 2 : 3
            label = "Cool & Quiet Mode"
        @unknown default:
            level = 0
            label = nil
        }
        setThermalLevel(level: level)
        self.thermalStateLabel = label
    }

    var thermalBadgeText: String {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            return "Rust Engine: Cool (Utility QoS)"
        case .fair:
            return "Rust Engine: Efficiency Cores"
        case .serious:
            return "Rust Engine: Throttled (Cooling)"
        case .critical:
            return "Rust Engine: Emergency Pacing"
        @unknown default:
            return "Rust Engine: Active"
        }
    }

    var thermalBadgeColor: Color {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            return .green
        case .fair:
            return .blue
        case .serious:
            return .orange
        case .critical:
            return .red
        @unknown default:
            return .green
        }
    }

    var staleProjects: [ScannedItem] {
        projectItems.filter { $0.activity == .stale }
    }

    var activeProjects: [ScannedItem] {
        projectItems.filter { $0.activity == .active }
    }

    var selectedItemCount: Int {
        let scannedIDs = Set(allScannedItems.map(\.id)).union(duplicateMemberIDs)
        return selectedIDs.intersection(scannedIDs).count
    }

    var allScannedItems: [ScannedItem] {
        safeCacheItems + projectItems + largeFileItems
    }

    var duplicateMemberIDs: Set<String> {
        Set(duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap { $0.members.map(\.id) })
    }

    var duplicateRedundantMembers: [DuplicateMember] {
        duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap { $0.members.filter { !$0.isKeepRecommended } }
    }

    var recommendedDuplicateBytes: UInt64 {
        duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .reduce(0) { $0.saturatingAdding($1.reclaimablePhysicalBytes) }
    }

    var duplicateGroupCount: Int {
        duplicateGroups.count
    }

    var selectedDuplicatePhysicalBytes: UInt64 {
        let selected = selectedIDs
        let regularIDs = Set(allScannedItems.map(\.id))
        return duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap(\.members)
            .filter {
                selected.contains($0.id)
                    && !regularIDs.contains($0.id)
                    && !$0.isKeepRecommended
            }
            .reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    var selectedDuplicateCount: Int {
        let selected = selectedIDs
        return duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap(\.members)
            .filter { selected.contains($0.id) && !$0.isKeepRecommended }
            .count
    }

    var selectedPhysicalBytes: UInt64 {
        let selected = Set(selectedIDs)
        let scannedBytes = allScannedItems
            .filter { selected.contains($0.id) && $0.risk != .highRiskCli }
            .reduce(UInt64(0)) { $0.saturatingAdding($1.physicalBytes) }
        return scannedBytes.saturatingAdding(selectedDuplicatePhysicalBytes)
    }

    var selectedDirectoryCount: Int {
        let selected = Set(selectedIDs)
        let regularCount = allScannedItems.filter {
            selected.contains($0.id) && $0.risk != .highRiskCli
        }.count
        return regularCount + duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap(\.members)
            .filter { selected.contains($0.id) && !$0.isKeepRecommended }
            .count
    }

    var protectedLargeFileIDs: Set<String> {
        Set(largeFileItems.filter { $0.risk == .highRiskCli }.map(\.id))
    }

    var selectedActiveProjectCount: Int {
        let selected = Set(selectedIDs)
        return projectItems.filter {
            $0.activity == .active && selected.contains($0.id)
        }.count
    }

    var selectedPhysicalGB: String {
        String(format: "%.2f GB", Double(selectedPhysicalBytes) / 1_000_000_000)
    }

    var projectedAvailableBytes: UInt64 {
        (diskOverview?.availableBytes ?? 0).saturatingAdding(selectedPhysicalBytes)
    }

    var recommendedCacheItems: [ScannedItem] {
        safeCacheItems
    }

    var recommendedStaleProjectItems: [ScannedItem] {
        staleProjects
    }

    var recommendedInstallerItems: [ScannedItem] {
        largeFileItems.filter { item in
            guard item.risk == .safe else { return false }
            let extensionName = URL(fileURLWithPath: item.path).pathExtension.lowercased()
            return extensionName == "dmg" || extensionName == "pkg"
        }
    }

    var recommendedCacheBytes: UInt64 {
        physicalBytes(for: recommendedCacheItems)
    }

    var recommendedStaleProjectBytes: UInt64 {
        physicalBytes(for: recommendedStaleProjectItems)
    }

    var recommendedInstallerBytes: UInt64 {
        physicalBytes(for: recommendedInstallerItems)
    }

    var recommendedReclaimBytes: UInt64 {
        physicalBytes(for: recommendedItems)
    }

    var recommendedReclaimGB: String {
        byteCount(recommendedReclaimBytes)
    }

    var recommendedItems: [ScannedItem] {
        var items: [ScannedItem] = []
        if smartCleanIncludeCaches { items += recommendedCacheItems }
        if smartCleanIncludeStaleProjects { items += recommendedStaleProjectItems }
        if smartCleanIncludeInstallers { items += recommendedInstallerItems }
        return items
    }

    var recommendedDuplicateIDs: Set<String> {
        []
    }

    var selectedBreakdown: [SelectionBreakdown] {
        let selected = Set(selectedIDs)
        let items = allScannedItems.filter { selected.contains($0.id) && $0.risk != .highRiskCli }
        let grouped = Dictionary(grouping: items, by: { $0.category.isEmpty ? "Other selected items" : $0.category })
        var breakdowns: [SelectionBreakdown] = grouped.keys.sorted().compactMap { category in
            guard let values = grouped[category] else { return nil }
            return SelectionBreakdown(
                category: category,
                count: values.count,
                physicalBytes: physicalBytes(for: values)
            )
        }
        let selectedDuplicates = duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap(\.members)
            .filter { selected.contains($0.id) && !$0.isKeepRecommended }
        if !selectedDuplicates.isEmpty {
            breakdowns.append(
                SelectionBreakdown(
                    category: "Duplicate Files & Folders",
                    count: selectedDuplicates.count,
                    physicalBytes: selectedDuplicatePhysicalBytes
                )
            )
        }
        return breakdowns
    }

    private var recommendedIDs: Set<String> {
        Set(recommendedItems.map(\.id)).union(recommendedDuplicateIDs)
    }

    private func physicalBytes(for items: [ScannedItem]) -> UInt64 {
        items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    /// Cancels the Swift task and tells Rust to stop its walkers and hashers.
    /// Cancelling only the task would let the detached Rust scan keep reading
    /// the disk with nobody left to use its result.
    private func cancelRunningScanWork() {
        activeScanTask?.cancel()
        cancelActiveScan()
    }

    func status(for category: NavigationTab) -> CategoryScanStatus {
        categoryStatus[category] ?? .notScanned
    }

    func scanCategory(_ category: NavigationTab) {
        guard activeScanningCategory != category else { return }

        // Cancel running scan work cleanly before starting a new scan
        cancelRunningScanWork()
        updateThermalState()

        activeScanningCategory = category
        categoryStatus[category] = .scanning
        isScanning = true
        scanProgress = 0.0
        scanPhase = "Scanning \(category.rawValue)…"
        scanPhaseDetail = categoryScanDetail(for: category)
        statusBanner = scanPhase

        let home = homeDirectory
        let staleThreshold = staleThresholdDays
        let threshold = largeFileThresholdBytes
        let includeDevCaches = !hideLargeFileDevCaches
        let duplicateThreshold = duplicateMinSizeBytes

        activeScanTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }

            switch category {
            case .safeCaches:
                let caches = await Task.detached(priority: .utility) {
                    scanSafeCaches(homeDir: home)
                }.value
                guard !Task.isCancelled else { return }
                self.safeCacheItems = caches
                self.selectedIDs.formUnion(caches.map(\.id))
                let bytes = self.physicalBytes(for: caches)
                self.categoryStatus[.safeCaches] = .completed(
                    itemCount: caches.count,
                    totalPhysicalBytes: bytes,
                    timestamp: Date()
                )
                self.statusBanner = "Finished scanning \(category.rawValue): found \(caches.count) item(s) (\(self.byteCount(bytes)))."

            case .projects:
                let projects = await Task.detached(priority: .utility) {
                    scanProjectArtifacts(rootPath: home, staleThresholdDays: staleThreshold)
                }.value
                guard !Task.isCancelled else { return }
                self.projectItems = projects
                self.selectedIDs.subtract(Set(projects.map(\.id)))
                self.selectedIDs.formUnion(projects.filter { $0.activity == .stale }.map(\.id))
                let bytes = self.physicalBytes(for: projects)
                self.categoryStatus[.projects] = .completed(
                    itemCount: projects.count,
                    totalPhysicalBytes: bytes,
                    timestamp: Date()
                )
                self.statusBanner = "Finished scanning \(category.rawValue): classified \(projects.count) project folder(s) (\(self.byteCount(bytes)))."

            case .largeFiles:
                let largeFiles = await Task.detached(priority: .utility) {
                    scanLargeFilesWithOptions(
                        rootPath: home,
                        thresholdBytes: threshold,
                        includeDevCaches: includeDevCaches
                    )
                }.value
                guard !Task.isCancelled else { return }
                self.largeFileItems = largeFiles
                let installers = largeFiles.filter { $0.category == "Disk Images & Installers" && $0.risk != .highRiskCli }
                self.selectedIDs.formUnion(installers.map(\.id))
                let bytes = self.physicalBytes(for: largeFiles)
                self.categoryStatus[.largeFiles] = .completed(
                    itemCount: largeFiles.count,
                    totalPhysicalBytes: bytes,
                    timestamp: Date()
                )
                self.statusBanner = "Finished scanning \(category.rawValue): found \(largeFiles.count) file(s) (\(self.byteCount(bytes)))."

            case .duplicates:
                let duplicates = await Task.detached(priority: .utility) {
                    scanDuplicates(rootPath: home, minSizeBytes: duplicateThreshold)
                }.value
                guard !Task.isCancelled else { return }
                self.duplicateGroups = duplicates
                self.autoSelectRedundantDuplicates()
                let bytes = self.recommendedDuplicateBytes
                self.categoryStatus[.duplicates] = .completed(
                    itemCount: duplicates.count,
                    totalPhysicalBytes: bytes,
                    timestamp: Date()
                )
                self.statusBanner = "Finished scanning \(category.rawValue): found \(duplicates.count) twin group(s) (\(self.byteCount(bytes)))."

            case .packages:
                let packages = await Task.detached(priority: .utility) {
                    scanTerminalPackages(homeDir: home)
                }.value
                guard !Task.isCancelled else { return }
                self.terminalPackages = packages
                let bytes = packages.reduce(UInt64(0)) { $0.saturatingAdding($1.physicalBytes) }
                self.categoryStatus[.packages] = .completed(
                    itemCount: packages.count,
                    totalPhysicalBytes: bytes,
                    timestamp: Date()
                )
                self.statusBanner = "Finished scanning \(category.rawValue): found \(packages.count) tool(s) (\(self.byteCount(bytes)))."

            case .smartOverview:
                break
            }

            self.diskOverview = getDiskOverview()
            self.scanProgress = 1.0
            self.isScanning = false
            self.activeScanningCategory = nil
            self.activeScanTask = nil
        }
    }

    func scanFastJunk() {
        guard activeScanningCategory == nil else { return }
        cancelRunningScanWork()
        updateThermalState()

        isScanning = true
        activeScanningCategory = .smartOverview
        categoryStatus[.safeCaches] = .scanning
        categoryStatus[.projects] = .scanning
        scanProgress = 0.0
        scanPhase = "Scanning Fast Junk & Caches…"
        scanPhaseDetail = "Checking temporary caches and old project dependency folders…"
        statusBanner = scanPhase

        let home = homeDirectory
        let staleThreshold = staleThresholdDays

        activeScanTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }

            let (caches, projects) = await Task.detached(priority: .utility) {
                let c = scanSafeCaches(homeDir: home)
                let p = scanProjectArtifacts(rootPath: home, staleThresholdDays: staleThreshold)
                return (c, p)
            }.value

            guard !Task.isCancelled else { return }

            self.safeCacheItems = caches
            self.selectedIDs.formUnion(caches.map(\.id))
            let cacheBytes = self.physicalBytes(for: caches)
            self.categoryStatus[.safeCaches] = .completed(
                itemCount: caches.count,
                totalPhysicalBytes: cacheBytes,
                timestamp: Date()
            )

            self.projectItems = projects
            self.selectedIDs.subtract(Set(projects.map(\.id)))
            self.selectedIDs.formUnion(projects.filter { $0.activity == .stale }.map(\.id))
            let projectBytes = self.physicalBytes(for: projects)
            self.categoryStatus[.projects] = .completed(
                itemCount: projects.count,
                totalPhysicalBytes: projectBytes,
                timestamp: Date()
            )

            self.diskOverview = getDiskOverview()
            self.scanProgress = 1.0
            self.isScanning = false
            self.activeScanningCategory = nil
            self.activeScanTask = nil
            self.statusBanner = "Fast scan complete: found \(self.byteCount(cacheBytes.saturatingAdding(projectBytes))) in safe caches and old projects."
        }
    }

    func scanCurrentTab() {
        if selectedTab == .smartOverview {
            scanFastJunk()
        } else {
            scanCategory(selectedTab)
        }
    }

    func runScan() {
        scanCurrentTab()
    }

    func rescanLargeFiles() {
        scanCategory(.largeFiles)
    }

    func rescanProjects() {
        scanCategory(.projects)
    }

    func rescanDuplicates() {
        scanCategory(.duplicates)
    }

    private func categoryScanDetail(for category: NavigationTab) -> String {
        switch category {
        case .safeCaches:
            return "Checking ~/Library/Caches, browser caches, and package manager temp files…"
        case .projects:
            return "Inspecting manifest-backed node_modules, target, and build folders…"
        case .largeFiles:
            return "Finding files larger than \(byteCount(largeFileThresholdBytes)) across your home directory…"
        case .duplicates:
            return "Fingerprinting files and finding identical copies with BLAKE3…"
        case .packages:
            return "Checking Homebrew, Python, Node, Rust, and Docker virtual disk footprints…"
        case .smartOverview:
            return "Quick scan across safe caches and project artifacts…"
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        if let category = activeScanningCategory {
            if category == .smartOverview {
                if categoryStatus[.safeCaches] == .scanning { categoryStatus[.safeCaches] = .cancelled }
                if categoryStatus[.projects] == .scanning { categoryStatus[.projects] = .cancelled }
            } else {
                categoryStatus[category] = .cancelled
            }
        }
        cancelRunningScanWork()
        activeScanTask = nil
        activeScanningCategory = nil
        isScanning = false
        scanPhase = "Scan stopped"
        scanPhaseDetail = "Existing results were kept."
        statusBanner = "Scan stopped. Your Mac was not modified."
    }

    func quickCleanSafeJunk() {
        guard !isWorking, !isScanning else { return }
        deletionMode = .moveToTrash
        selectedIDs = recommendedIDs
        normalizeDuplicateSelections()
        guard selectedItemCount > 0 else {
            statusBanner = "No safe junk items found to clean."
            return
        }
        executeSelectedCleanup()
    }

    func resetToRecommended() {
        selectedIDs = recommendedIDs
        statusBanner = "Selections reset to the recommended safe baseline."
    }

    func selectRecommendedForReview() {
        selectedIDs = recommendedIDs
        statusBanner = "Recommended items are selected for review. Nothing has been removed."
    }

    func autoSelectRedundantDuplicates() {
        selectedIDs.formUnion(recommendedDuplicateIDs)
        for group in duplicateGroups {
            if group.kind == .duplicatePackage { continue }
            for member in group.members where member.isKeepRecommended {
                selectedIDs.remove(member.id)
            }
        }
        statusBanner = "Selected redundant copies while keeping one original in every group."
    }

    func swapDuplicateKeep(groupID: String, memberID: String) {
        guard let groupIndex = duplicateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = duplicateGroups[groupIndex]
        guard group.members.contains(where: { $0.id == memberID }) else { return }
        group.members = group.members.map { member in
            var updated = member
            updated.isKeepRecommended = member.id == memberID
            return updated
        }
        duplicateGroups[groupIndex] = group
        selectedIDs.remove(memberID)
        statusBanner = "Keep Original moved. The previous original is now available as a redundant copy."
    }

    func isDuplicateKeepLocked(_ member: DuplicateMember) -> Bool {
        member.isKeepRecommended && !allowDeleteAllDuplicateCopies
    }

    private func normalizeDuplicateSelections() {
        guard !allowDeleteAllDuplicateCopies else { return }
        for group in duplicateGroups where group.kind != .duplicatePackage {
            let selectedMembers = group.members.filter { selectedIDs.contains($0.id) }
            if selectedMembers.count >= group.members.count,
               let keep = group.members.first(where: { $0.isKeepRecommended }) {
                selectedIDs.remove(keep.id)
                statusBanner = "Always Keep 1 Copy prevented deleting every member of a duplicate group."
            }
        }
    }

    func executeSelectedCleanup() {
        guard selectedItemCount > 0, !isWorking else { return }

        let blockedTargets = selectedIDs.intersection(protectedLargeFileIDs)
        if !blockedTargets.isEmpty {
            selectedIDs.subtract(blockedTargets)
            selectedTab = .packages
            statusBanner = "Protected virtual disks must be managed from Terminal Packages with Docker Prune."
            return
        }

        if !unlockActiveProjectSelection {
            let activeIDs = Set(activeProjects.map(\.id))
            let lockedActiveIDs = selectedIDs.intersection(activeIDs)
            if !lockedActiveIDs.isEmpty {
                selectedIDs.subtract(lockedActiveIDs)
                statusBanner = "Active project dependencies were left selected only after you unlock them in Project Dependencies."
            }
        }

        normalizeDuplicateSelections()

        let duplicateTargetPaths = Set(duplicateGroups
            .filter { $0.kind != .duplicatePackage }
            .flatMap(\.members)
            .filter { selectedIDs.contains($0.id) && !$0.isKeepRecommended }
            .map(\.path))
        let cleanupIDs = selectedIDs
            .intersection(Set(allScannedItems.map(\.id)))
            .filter { !duplicateTargetPaths.contains($0) }
        let targets = Array(cleanupIDs) + Array(duplicateTargetPaths)
        guard !targets.isEmpty else { return }
        let deletePermanently = deletionMode == .permanentDelete
        let home = homeDirectory
        let threshold = largeFileThresholdBytes
        let staleThreshold = staleThresholdDays
        let includeDevCaches = !hideLargeFileDevCaches
        let duplicateThreshold = duplicateMinSizeBytes
        isWorking = true
        statusBanner = deletePermanently ? "Permanently deleting selected items…" : "Moving selected items to Trash…"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mode: DeletionMode = deletePermanently ? .permanentDelete : .moveToTrash
            let report = purgeItems(paths: targets, mode: mode)
            let caches = scanSafeCaches(homeDir: home)
            let projects = scanProjectArtifacts(rootPath: home, staleThresholdDays: staleThreshold)
            let largeFiles = scanLargeFilesWithOptions(
                rootPath: home,
                thresholdBytes: threshold,
                includeDevCaches: includeDevCaches
            )
            let duplicates = scanDuplicates(rootPath: home, minSizeBytes: duplicateThreshold)
            let overview = getDiskOverview()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.safeCacheItems = caches
                self.projectItems = projects
                self.largeFileItems = largeFiles
                self.duplicateGroups = duplicates
                self.diskOverview = overview
                let remainingIDs = Set(
                    caches.map(\.id)
                        + projects.map(\.id)
                        + largeFiles.map(\.id)
                        + duplicates.flatMap { $0.members.map(\.id) }
                )
                self.selectedIDs = Set(targets).intersection(remainingIDs)
                self.isWorking = false

                var status = self.cleanupStatus(for: report, mode: mode)
                if report.skippedLockedCount > 0 {
                    status += " Skipped \(report.skippedLockedCount) locked item(s)."
                }
                if !report.errors.isEmpty {
                    status += " \(report.errors.count) error(s)."
                }
                self.statusBanner = status
                self.showingOpenTrashAction = !deletePermanently && report.deletedItemsCount > 0
                if report.skippedLockedCount > 0 || !report.errors.isEmpty {
                    self.diagnosticSkippedPaths = targets.filter { path in
                        self.selectedIDs.contains(path) || report.errors.contains { $0.contains(path) }
                    }
                    self.diagnosticMessage = self.recoveryMessage(
                        skippedCount: report.skippedLockedCount,
                        errorCount: report.errors.count
                    )
                    self.showingDiagnosticDetails = true
                } else {
                    self.diagnosticSkippedPaths = []
                    self.diagnosticMessage = nil
                    self.showingDiagnosticDetails = false
                }
            }
        }
    }

    /// Banner text after a cleanup. Items moved to the Trash still occupy the
    /// volume, so only a permanent delete may claim that space was freed.
    func cleanupStatus(for report: CleanupReport, mode: DeletionMode) -> String {
        switch mode {
        case .moveToTrash:
            guard report.deletedItemsCount > 0 else { return "Nothing was moved to Trash." }
            return "Moved \(byteCount(report.trashedPhysicalBytes)) to Trash. Empty Trash to reclaim space. \(report.deletedItemsCount) item(s) moved."
        case .permanentDelete:
            guard report.deletedItemsCount > 0 else { return "Nothing was deleted." }
            return "Permanently freed \(byteCount(report.permanentlyFreedPhysicalBytes)). \(report.deletedItemsCount) item(s) deleted."
        }
    }

    func requestCleanup() {
        guard selectedItemCount > 0 else { return }
        let blockedTargets = selectedIDs.intersection(protectedLargeFileIDs)
        if !blockedTargets.isEmpty {
            selectedIDs.subtract(blockedTargets)
            selectedTab = .packages
            statusBanner = "Protected virtual disks must be managed from Terminal Packages with Docker Prune."
            return
        }
        if !unlockActiveProjectSelection {
            let activeIDs = Set(activeProjects.map(\.id))
            let lockedActiveIDs = selectedIDs.intersection(activeIDs)
            if !lockedActiveIDs.isEmpty {
                selectedIDs.subtract(lockedActiveIDs)
                statusBanner = "Active project dependencies are locked. Unlock them in Project Dependencies before cleaning."
            }
        }
        normalizeDuplicateSelections()
        guard selectedItemCount > 0 else { return }
        showingPermanentDeleteConfirmation = true
    }

    func requestDuplicateCleanup() {
        guard !isWorking else { return }
        selectedIDs = selectedIDs.intersection(duplicateMemberIDs)
        normalizeDuplicateSelections()
        guard selectedDuplicateCount > 0 else {
            statusBanner = "Select one or more redundant copies first. The protected original cannot be removed."
            return
        }
        showingPermanentDeleteConfirmation = true
    }

    func confirmPermanentCleanup() {
        showingPermanentDeleteConfirmation = false
        executeSelectedCleanup()
    }

    var permanentDeleteConfirmationMessage: String {
        var message = "Permanently delete \(selectedDirectoryCount) selected item(s) and reclaim \(byteCount(selectedPhysicalBytes)) of physical APFS storage?"
        if selectedActiveProjectCount > 0 {
            message += "\n\nWarning: this includes \(selectedActiveProjectCount) active project dependency folder(s)."
        }
        message += "\n\nLocked paths will be skipped and reported."
        return message
    }

    func openTerminalPackagesForProtectedItem() {
        selectedTab = .packages
        statusBanner = "Use Docker Prune in Terminal Packages for protected virtual disks."
    }

    func openTrash() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if FileManager.default.fileExists(atPath: trashURL.path) {
            NSWorkspace.shared.open(trashURL)
        } else {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealDiagnosticPaths() {
        guard let firstPath = diagnosticSkippedPaths.first else { return }
        FinderSupport.reveal(path: firstPath)
    }

    private func recoveryMessage(skippedCount: UInt32, errorCount: Int) -> String {
        var parts: [String] = []
        if skippedCount > 0 {
            parts.append("\(skippedCount) item(s) were skipped because an app is currently using them or macOS permission is needed.")
        }
        if errorCount > 0 {
            parts.append("\(errorCount) item(s) could not be cleaned and were left untouched for safety.")
        }
        return parts.joined(separator: " ")
    }

    func refreshDiskOverview() {
        diskOverview = getDiskOverview()
    }

    func requestPackageAction(_ package: TerminalPackage) {
        guard !isWorking else { return }
        pendingPackageAction = package
        showingPackageActionConfirmation = true
    }

    func confirmPackageAction() {
        guard let package = pendingPackageAction else { return }
        pendingPackageAction = nil
        showingPackageActionConfirmation = false
        let manager = package.manager
        let packageName = package.name
        let packagePath = package.path
        let command = package.uninstallCmd
        let home = homeDirectory

        isWorking = true
        statusBanner = "Running \(command)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let report = try runTerminalUninstall(
                    manager: manager,
                    packageName: packageName,
                    path: packagePath
                )
                let packages = scanTerminalPackages(homeDir: home)
                let overview = getDiskOverview()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.terminalPackages = packages
                    self.diskOverview = overview
                    self.isWorking = false
                    self.statusBanner = self.packageActionStatus(report)
                    if !report.success || !report.stderr.isEmpty {
                        self.diagnosticMessage = "The package action could not be completed. The item might be busy, in use by another program, or require Full Disk Access."
                        self.diagnosticSkippedPaths = [packagePath]
                        self.showingDiagnosticDetails = true
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isWorking = false
                    self.statusBanner = "Action could not finish. Your files were not touched."
                    self.diagnosticMessage = "The command could not be completed. Check that the tool is installed, not in use by another program, and Full Disk Access is enabled."
                    self.diagnosticSkippedPaths = [packagePath]
                    self.showingDiagnosticDetails = true
                }
            }
        }
    }

    func requestMaintenance(_ action: String) {
        guard !isWorking else { return }
        pendingMaintenanceAction = action
        showingMaintenanceConfirmation = true
    }

    func confirmMaintenance() {
        guard let action = pendingMaintenanceAction else { return }
        pendingMaintenanceAction = nil
        showingMaintenanceConfirmation = false
        let home = homeDirectory
        let command = maintenanceCommand(action)
        isWorking = true
        statusBanner = "Running \(command)…"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let report = try runPackageMaintenance(action: action)
                let packages = scanTerminalPackages(homeDir: home)
                let overview = getDiskOverview()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.terminalPackages = packages
                    self.diskOverview = overview
                    self.isWorking = false
                    self.statusBanner = self.packageActionStatus(report)
                    if !report.success || !report.stderr.isEmpty {
                        self.diagnosticMessage = report.stderr.isEmpty
                            ? "The maintenance command did not complete successfully."
                            : report.stderr
                        self.diagnosticSkippedPaths = []
                        self.showingDiagnosticDetails = true
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isWorking = false
                    self.statusBanner = "Maintenance action failed: \(error.localizedDescription)"
                    self.diagnosticMessage = "The maintenance command could not be completed. Confirm the CLI tool is installed and try again."
                    self.diagnosticSkippedPaths = []
                    self.showingDiagnosticDetails = true
                }
            }
        }
    }

    func maintenanceCommand(_ action: String) -> String {
        switch action {
        case "brew_cleanup": return "brew cleanup --prune=all"
        case "brew_autoremove": return "brew autoremove"
        case "docker_prune": return "docker system prune -a --volumes -f"
        default: return action
        }
    }

    /// Shown before every Docker prune, whichever button started it.
    static let dockerPruneWarning = "This will run `docker system prune -a --volumes -f`. This permanently deletes ALL stopped containers, ALL unused networks, ALL unused images, and ALL volumes (including database data)."

    var packageConfirmationMessage: String {
        guard let package = pendingPackageAction else { return "" }
        if package.manager == "Container VM" {
            return "\(Self.dockerPruneWarning)\n\nThis cannot be undone. Current physical footprint of the selected item: \(byteCount(package.physicalBytes))."
        }
        var message = "Execute \(package.uninstallCmd)?\n\nCurrent physical footprint: \(byteCount(package.physicalBytes))."
        if package.installedOnRequest == false && package.manager == "Homebrew Formula" {
            message += "\n\nWarning: this formula was not installed explicitly. Other Homebrew packages may depend on it."
        }
        return message
    }

    var maintenanceConfirmationMessage: String {
        guard let action = pendingMaintenanceAction else { return "" }
        let command = maintenanceCommand(action)
        if action == "docker_prune" {
            return "\(Self.dockerPruneWarning)\n\nThis cannot be undone."
        }
        return "Execute \(command)?\n\nThis runs global package maintenance and may remove unused package data."
    }

    private func packageActionStatus(_ report: PackageActionReport) -> String {
        let measured = byteCount(report.freedPhysicalBytes)
        let summary = report.stdout
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? report.stderr.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        var status = report.success
            ? "Completed \(report.commandRun); freed \(measured)."
            : "Command failed: \(report.commandRun)."
        if !summary.isEmpty {
            status += " \(summary)"
        }
        return status
    }

    func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    func naturalAge(_ days: UInt64) -> String {
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<30: return "\(days) days ago"
        case 30..<365: return "\(days / 30) month\(days / 30 == 1 ? "" : "s") ago"
        default: return "Over 1 year ago"
        }
    }
}

struct SelectionBreakdown: Identifiable {
    let category: String
    let count: Int
    let physicalBytes: UInt64

    var id: String { category }
}
