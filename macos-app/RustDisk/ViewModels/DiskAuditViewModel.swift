import Foundation
import AppKit
import SwiftUI

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

    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private var activeScanTask: Task<Void, Never>?

    var scanPercentText: String {
        "\(Int((scanProgress * 100).rounded()))%"
    }

    init() {
        diskOverview = getDiskOverview()
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

    func runScan() {
        guard !isScanning else { return }

        cancelRunningScanWork()
        isScanning = true
        scanPhaseIndex = 1
        scanProgress = 0.0
        scanDiscoveredBytes = 0
        scanPhase = "1/5 Scanning Safe Caches…"
        scanPhaseDetail = "Enumerating cache directories and measuring physical APFS allocation…"
        statusBanner = scanPhase
        let home = homeDirectory
        let threshold = largeFileThresholdBytes
        let duplicateThreshold = duplicateMinSizeBytes
        let staleThreshold = staleThresholdDays
        let includeDevCaches = !hideLargeFileDevCaches

        activeScanTask = Task { @MainActor [weak self] in
            let caches = await Task.detached(priority: .utility) {
                scanSafeCaches(homeDir: home)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.safeCacheItems = caches
            self.scanDiscoveredBytes = self.physicalBytes(for: caches)
            self.scanProgress = 0.25
            self.scanPhaseIndex = 2
            self.scanPhase = "2/5 Analyzing Project Activity…"
            self.scanPhaseDetail = "Finding recognized project artifacts while preserving source files and .git directories…"
            self.statusBanner = self.scanPhase

            let projects = await Task.detached(priority: .utility) {
                scanProjectArtifacts(rootPath: home, staleThresholdDays: staleThreshold)
            }.value
            guard !Task.isCancelled else { return }
            self.projectItems = projects
            self.scanDiscoveredBytes = self.scanDiscoveredBytes.saturatingAdding(self.physicalBytes(for: projects))
            self.scanProgress = 0.5
            self.scanPhaseIndex = 3
            self.scanPhase = "3/5 Inspecting Terminal Packages…"
            self.scanPhaseDetail = "Reading package receipts, runtime versions, and CLI-managed installations…"
            self.statusBanner = self.scanPhase

            let packages = await Task.detached(priority: .utility) {
                scanTerminalPackages(homeDir: home)
            }.value
            guard !Task.isCancelled else { return }
            self.terminalPackages = packages
            self.scanDiscoveredBytes = self.scanDiscoveredBytes.saturatingAdding(
                packages.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
            )
            self.scanProgress = 0.75
            self.scanPhaseIndex = 4
            self.scanPhase = "4/5 Hunting Large Files…"
            self.scanPhaseDetail = "Scanning eligible files and comparing physical APFS allocation…"
            self.statusBanner = self.scanPhase

            let largeFiles = await Task.detached(priority: .utility) {
                scanLargeFilesWithOptions(
                    rootPath: home,
                    thresholdBytes: threshold,
                    includeDevCaches: includeDevCaches
                )
            }.value
            guard !Task.isCancelled else { return }
            self.largeFileItems = largeFiles
            self.scanDiscoveredBytes = self.scanDiscoveredBytes.saturatingAdding(self.physicalBytes(for: largeFiles))
            self.scanPhase = "5/5 Finding Duplicate Files, Folders & Packages…"
            self.scanPhaseDetail = "Indexing candidates, fingerprinting content, and hashing exact matches…"
            self.statusBanner = self.scanPhase
            self.scanPhaseIndex = 5
            self.scanProgress = 0.9
            let duplicates = await Task.detached(priority: .utility) {
                scanDuplicates(rootPath: home, minSizeBytes: duplicateThreshold)
            }.value
            guard !Task.isCancelled else { return }
            self.duplicateGroups = duplicates
            self.diskOverview = getDiskOverview()
            self.selectedIDs = self.recommendedIDs
            self.scanProgress = 1.0
            self.scanPhaseIndex = 5
            self.isScanning = false
            self.scanPhaseDetail = "All scan stages finished."
            self.statusBanner = "Scan complete: \(caches.count) caches, \(projects.count) project artifacts, \(packages.count) packages, \(largeFiles.count) large files, \(duplicates.count) duplicate groups."
            self.activeScanTask = nil
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        cancelRunningScanWork()
        activeScanTask = nil
        isScanning = false
        scanPhase = "Scan cancelled"
        scanPhaseDetail = "Existing results were kept."
        statusBanner = "Scan cancelled. Existing results are still available."
    }

    func resetToRecommended() {
        selectedIDs = recommendedIDs
        statusBanner = "Selections reset to the recommended safe baseline."
    }

    func selectRecommendedForReview() {
        selectedIDs = recommendedIDs
        statusBanner = "Recommended items are selected for review. Nothing has been removed."
    }

    func rescanLargeFiles() {
        guard !isScanning else { return }

        cancelRunningScanWork()
        isScanning = true
        scanPhaseIndex = 4
        scanProgress = 0.75
        scanPhase = "4/5 Hunting Large Files…"
        scanPhaseDetail = "Scanning eligible files and comparing physical APFS allocation…"
        statusBanner = scanPhase
        let home = homeDirectory
        let threshold = largeFileThresholdBytes
        let includeDevCaches = !hideLargeFileDevCaches
        let previousLargeFileIDs = Set(largeFileItems.map(\.id))
        let previouslySelectedLargeFileIDs = selectedIDs.intersection(previousLargeFileIDs)

        activeScanTask = Task { @MainActor [weak self] in
            let largeFiles = await Task.detached(priority: .utility) {
                scanLargeFilesWithOptions(
                    rootPath: home,
                    thresholdBytes: threshold,
                    includeDevCaches: includeDevCaches
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.largeFileItems = largeFiles
            self.selectedIDs.subtract(previousLargeFileIDs)
            self.selectedIDs.formUnion(
                previouslySelectedLargeFileIDs.intersection(Set(largeFiles.map(\.id)))
            )
            self.scanDiscoveredBytes = self.physicalBytes(for: largeFiles)
            self.scanProgress = 1.0
            self.isScanning = false
            self.scanPhaseDetail = "Large-file scan finished."
            self.statusBanner = "Large-file scan complete: \(largeFiles.count) files found."
            self.activeScanTask = nil
        }
    }

    func rescanProjects() {
        guard !isScanning else { return }

        cancelRunningScanWork()
        isScanning = true
        scanPhaseIndex = 2
        scanProgress = 0.25
        scanPhase = "2/5 Analyzing Project Activity…"
        scanPhaseDetail = "Finding recognized project artifacts while preserving source files and .git directories…"
        statusBanner = scanPhase
        let home = homeDirectory
        let staleThreshold = staleThresholdDays

        activeScanTask = Task { @MainActor [weak self] in
            let projects = await Task.detached(priority: .utility) {
                scanProjectArtifacts(rootPath: home, staleThresholdDays: staleThreshold)
            }.value
            guard !Task.isCancelled, let self else { return }
            let oldProjectIDs = Set(self.projectItems.map(\.id))
            self.projectItems = projects
            self.selectedIDs.subtract(oldProjectIDs)
            self.selectedIDs.formUnion(projects.filter { $0.activity == .stale }.map(\.id))
            self.scanDiscoveredBytes = self.physicalBytes(for: projects)
            self.scanProgress = 1.0
            self.isScanning = false
            self.scanPhaseDetail = "Project activity scan finished."
            self.statusBanner = "Project activity refreshed: \(projects.count) artifact(s) classified."
            self.activeScanTask = nil
        }
    }

    func rescanDuplicates() {
        guard !isScanning else { return }
        cancelRunningScanWork()
        isScanning = true
        scanPhaseIndex = 5
        scanProgress = 0.9
        scanPhase = "5/5 Finding Duplicate Files, Folders & Packages…"
        scanPhaseDetail = "Indexing candidates, fingerprinting content, and hashing exact matches…"
        statusBanner = scanPhase
        let home = homeDirectory
        let threshold = duplicateMinSizeBytes
        let previousIDs = Set(duplicateGroups.flatMap { $0.members.map(\.id) })
        let selectedDuplicateIDs = selectedIDs.intersection(previousIDs)

        activeScanTask = Task { @MainActor [weak self] in
            let duplicates = await Task.detached(priority: .utility) {
                scanDuplicates(rootPath: home, minSizeBytes: threshold)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.duplicateGroups = duplicates
            let newIDs = Set(duplicates.flatMap { $0.members.map(\.id) })
            self.selectedIDs.subtract(previousIDs)
            self.selectedIDs.formUnion(selectedDuplicateIDs.intersection(newIDs))
            self.scanProgress = 1.0
            self.isScanning = false
            self.scanPhaseDetail = "Duplicate scan finished."
            self.statusBanner = "Duplicate scan complete: \(duplicates.count) group(s) found."
            self.activeScanTask = nil
        }
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

            DispatchQueue.main.async {
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
            parts.append("\(skippedCount) item(s) are currently in use or require Full Disk Access.")
        }
        if errorCount > 0 {
            parts.append("\(errorCount) item(s) returned an error and were left untouched.")
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
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.terminalPackages = packages
                    self.diskOverview = overview
                    self.isWorking = false
                    self.statusBanner = self.packageActionStatus(report)
                    if !report.success || !report.stderr.isEmpty {
                        self.diagnosticMessage = report.stderr.isEmpty
                            ? "The CLI action did not complete successfully. Review the command output before trying again."
                            : report.stderr
                        self.diagnosticSkippedPaths = [packagePath]
                        self.showingDiagnosticDetails = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.statusBanner = "CLI action failed: \(error.localizedDescription)"
                    self.diagnosticMessage = "The command could not be completed. Check that the tool is installed, Full Disk Access is available, and the package is not in use."
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
                DispatchQueue.main.async {
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
                DispatchQueue.main.async {
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

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
