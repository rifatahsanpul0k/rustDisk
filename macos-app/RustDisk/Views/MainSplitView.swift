import AppKit
import SwiftUI

enum NavigationTab: String, CaseIterable, Identifiable {
    case smartOverview = "Smart Overview"
    case safeCaches = "Safe Caches"
    case projects = "Project Dependencies"
    case packages = "Terminal Packages"
    case largeFiles = "Large File Finder"
    case duplicates = "Duplicates"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartOverview: return "sparkles.rectangle.stack.fill"
        case .safeCaches: return "sparkles"
        case .projects: return "hammer.fill"
        case .packages: return "terminal.fill"
        case .largeFiles: return "externaldrive.fill.badge.timemachine"
        case .duplicates: return "square.on.square"
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedTab) {
                Section("Overview") {
                    tabRow(.smartOverview)
                }
                Section("Audit") {
                    ForEach(NavigationTab.allCases.dropFirst()) { tab in
                        tabRow(tab)
                    }
                }
            }
            .navigationTitle("RustDisk")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235)
        } detail: {
            VStack(spacing: 0) {
                controlBar
                if viewModel.isScanning {
                    scanProgressBanner
                }
                StorageHeaderView()
                diagnosticRecoveryCard
                Divider()

                Group {
                    switch viewModel.selectedTab {
                    case .smartOverview:
                        SmartOverviewView()
                    case .safeCaches:
                        SafeCachesView()
                    case .projects:
                        ProjectsView()
                    case .packages:
                        PackagesView()
                    case .largeFiles:
                        LargeFilesView()
                    case .duplicates:
                        DuplicatesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                footer
            }
        }
        .sheet(isPresented: $viewModel.showingPermanentDeleteConfirmation) {
            CleanupConfirmationSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showingSafetyGuide) {
            SafetyGuideSheet()
        }
        .alert("Confirm Package Action", isPresented: $viewModel.showingPackageActionConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Execute", role: .destructive) {
                viewModel.confirmPackageAction()
            }
        } message: {
            Text(viewModel.packageConfirmationMessage)
        }
        .alert("Confirm Maintenance Action", isPresented: $viewModel.showingMaintenanceConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Execute", role: .destructive) {
                viewModel.confirmMaintenance()
            }
        } message: {
            Text(viewModel.maintenanceConfirmationMessage)
        }
    }

    private func tabRow(_ tab: NavigationTab) -> some View {
        Label(tab.rawValue, systemImage: tab.icon)
            .tag(tab)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Label("RustDisk", systemImage: "internaldrive.fill")
                .font(.headline)

            Spacer()

            Button {
                viewModel.showingSafetyGuide = true
            } label: {
                Label("Safety & APFS Guide", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)

            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    viewModel.runScan()
                } label: {
                    Label("Scan Now", systemImage: "magnifyingglass")
                }
                .disabled(viewModel.isWorking)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var scanProgressBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scan Progress")
                    .font(.headline)
                Spacer()
                Text(viewModel.scanPercentText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            ProgressView(value: viewModel.scanProgress)
                .tint(.accentColor)
                .animation(.easeInOut(duration: 0.25), value: viewModel.scanProgress)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.scanPhase)
                        .font(.callout.weight(.medium))
                    Text(viewModel.scanPhaseDetail)
                }
                Spacer()
                Text("Found \(viewModel.byteCount(viewModel.scanDiscoveredBytes))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private var diagnosticRecoveryCard: some View {
        if viewModel.showingDiagnosticDetails, let message = viewModel.diagnosticMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Some items need attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        viewModel.showingDiagnosticDetails = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss diagnostic details")
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Open Full Disk Access Settings") {
                        viewModel.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.bordered)
                    Button("Reveal Skipped Items in Finder") {
                        viewModel.revealDiagnosticPaths()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.diagnosticSkippedPaths.isEmpty)
                    Button("Dismiss") {
                        viewModel.showingDiagnosticDetails = false
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.10))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(viewModel.statusBanner)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if viewModel.showingOpenTrashAction {
                Button("Open Trash", systemImage: "trash") {
                    viewModel.openTrash()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Reset to Recommended") {
                viewModel.resetToRecommended()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking || viewModel.isScanning)

            if viewModel.selectedTab != .duplicates,
               viewModel.selectedTab != .packages,
               viewModel.selectedTab != .smartOverview,
               viewModel.selectedItemCount > 0 {
                Button(role: viewModel.deletionMode == .permanentDelete ? .destructive : nil) {
                    viewModel.requestCleanup()
                } label: {
                    Text("Review Cleanup (\(viewModel.selectedItemCount))")
                }
                .disabled(viewModel.isWorking)
                .buttonStyle(.borderedProminent)
                .tint(viewModel.deletionMode == .permanentDelete ? .red : .blue)
            }
        }
        .padding(12)
    }
}

struct CleanupConfirmationSheet: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Review Cleanup", systemImage: "checklist")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text(viewModel.deletionMode == .permanentDelete
                 ? "You selected \(viewModel.selectedDirectoryCount) item(s). Deleting them permanently frees \(viewModel.byteCount(viewModel.selectedPhysicalBytes)) of physical APFS storage."
                 : "You selected \(viewModel.selectedDirectoryCount) item(s) (\(viewModel.byteCount(viewModel.selectedPhysicalBytes))). Moving them to the Trash frees no space until you empty the Trash.")
                .font(.body)

            Picker("Cleanup action", selection: $viewModel.deletionMode) {
                Text("Move to Trash").tag(DeletionMode.moveToTrash)
                Text("Permanent Delete").tag(DeletionMode.permanentDelete)
            }
            .pickerStyle(.segmented)

            HStack {
                Text(viewModel.deletionMode == .permanentDelete
                     ? "Permanent Delete — Irreversible"
                     : "Move to Trash — Recoverable")
                    .font(.headline)
                    .foregroundStyle(viewModel.deletionMode == .permanentDelete ? .red : .blue)
                Spacer()
            }
            .padding(10)
            .background((viewModel.deletionMode == .permanentDelete ? Color.red : Color.blue).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                Text("Selected breakdown")
                    .font(.headline)
                ForEach(viewModel.selectedBreakdown) { breakdown in
                    HStack {
                        Text(breakdown.category)
                        Spacer()
                        Text("\(breakdown.count) · \(viewModel.byteCount(breakdown.physicalBytes))")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if viewModel.selectedActiveProjectCount > 0 {
                warning("Active project dependencies are included. Source files are not targeted, but these projects were used recently.")
            }

            Text("Locked paths and protected system locations will be skipped and reported.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button(viewModel.deletionMode == .permanentDelete ? "Permanently Delete" : "Move to Trash") {
                    dismiss()
                    if viewModel.deletionMode == .permanentDelete {
                        viewModel.confirmPermanentCleanup()
                    } else {
                        viewModel.executeSelectedCleanup()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.deletionMode == .permanentDelete ? .red : .blue)
            }
        }
        .padding(24)
        .frame(width: 590)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
