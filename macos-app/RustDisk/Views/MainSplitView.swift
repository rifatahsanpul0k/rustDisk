import AppKit
import SwiftUI

enum NavigationTab: String, CaseIterable, Identifiable {
    case smartOverview = "Quick Clean"
    case safeCaches = "Junk & Temp Files"
    case projects = "Old Coding Folders"
    case largeFiles = "Big Files"
    case duplicates = "Twin Files"
    case packages = "Apps & Dev Tools"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartOverview: return "sparkles"
        case .safeCaches: return "trash.fill"
        case .projects: return "hammer.fill"
        case .largeFiles: return "externaldrive.fill"
        case .duplicates: return "square.on.square"
        case .packages: return "shippingbox.fill"
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $viewModel.selectedTab) {
                Section("Dashboard") {
                    tabRow(.smartOverview)
                }
                Section("Audit Modules") {
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
        HStack {
            Label(tab.rawValue, systemImage: tab.icon)
            Spacer()
            if viewModel.activeScanningCategory == tab || (viewModel.activeScanningCategory == .smartOverview && (tab == .safeCaches || tab == .projects)) {
                ProgressView()
                    .controlSize(.mini)
            } else if case let .completed(count, bytes, _) = viewModel.status(for: tab), count > 0 {
                Text(viewModel.byteCount(bytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .tag(tab)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Label("RustDisk", systemImage: "internaldrive.fill")
                .font(.headline)

            Spacer()

            Button {
                viewModel.showProDetails.toggle()
            } label: {
                Label("Pro Details", systemImage: viewModel.showProDetails ? "slider.horizontal.3" : "slider.horizontal.below.square.and.square")
            }
            .buttonStyle(.bordered)
            .tint(viewModel.showProDetails ? .blue : nil)
            .help("Toggle technical paths, block counts, and CLI restore commands.")

            Button {
                viewModel.showingSafetyGuide = true
            } label: {
                Label("Safety Guide", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .help("Learn how RustDisk protects your Mac.")

            if viewModel.isScanning {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop Scan", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCurrentTab()
                } label: {
                    Label(
                        viewModel.selectedTab == .smartOverview ? "Scan Fast Junk" : "Scan \(viewModel.selectedTab.rawValue)",
                        systemImage: viewModel.selectedTab == .smartOverview ? "bolt.fill" : "magnifyingglass"
                    )
                }
                .disabled(viewModel.isWorking)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan current category (Cmd + R)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var scanProgressBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning Mac Storage…")
                    .font(.headline)
                Spacer()
                Text(viewModel.scanPercentText)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private var diagnosticRecoveryCard: some View {
        if viewModel.showingDiagnosticDetails, let message = viewModel.diagnosticMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Some items were skipped", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        viewModel.showingDiagnosticDetails = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss details")
                }

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Open Full Disk Access Settings") {
                        viewModel.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.bordered)

                    Button("Show in Finder") {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.10))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(viewModel.statusBanner)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if viewModel.showingOpenTrashAction {
                Button("Open Trash", systemImage: "trash") {
                    viewModel.openTrash()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Reset Selection") {
                viewModel.resetToRecommended()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking || viewModel.isScanning)

            if viewModel.selectedTab != .duplicates,
               viewModel.selectedTab != .packages,
               viewModel.selectedTab != .smartOverview,
               viewModel.selectedItemCount > 0 {

                HStack(spacing: 6) {
                    Button {
                        viewModel.deletionMode = .moveToTrash
                        viewModel.requestCleanup()
                    } label: {
                        Text("Move to Trash (\(viewModel.selectedItemCount))")
                    }
                    .disabled(viewModel.isWorking)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Menu {
                        Button(role: .destructive) {
                            viewModel.deletionMode = .permanentDelete
                            viewModel.requestCleanup()
                        } label: {
                            Label("Delete Permanently…", systemImage: "trash.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Advanced deletion options")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

struct CleanupConfirmationSheet: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    viewModel.deletionMode == .permanentDelete
                        ? "Permanently Delete Selected Items"
                        : "Move Selected Items to Trash",
                    systemImage: viewModel.deletionMode == .permanentDelete ? "exclamationmark.triangle.fill" : "trash.fill"
                )
                .font(.title2.bold())
                .foregroundStyle(viewModel.deletionMode == .permanentDelete ? .red : .green)

                Spacer()

                Button("Cancel") { dismiss() }
            }

            Text(
                viewModel.deletionMode == .permanentDelete
                    ? "Warning: Permanent deletion cannot be undone. Selected items (\(viewModel.byteCount(viewModel.selectedPhysicalBytes))) will be immediately removed from your disk."
                    : "Selected items (\(viewModel.byteCount(viewModel.selectedPhysicalBytes))) will be moved safely to your macOS Trash. You can restore them anytime by clicking 'Put Back' in Trash."
            )
            .font(.body)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Selected breakdown")
                    .font(.headline)
                ForEach(viewModel.selectedBreakdown) { breakdown in
                    HStack {
                        Text(breakdown.category)
                        Spacer()
                        Text("\(breakdown.count) item(s) · \(viewModel.byteCount(breakdown.physicalBytes))")
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if viewModel.selectedActiveProjectCount > 0 {
                Label("Warning: \(viewModel.selectedActiveProjectCount) active project dependencies are selected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("System folders and protected files are locked and will be skipped.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button(
                    viewModel.deletionMode == .permanentDelete ? "Delete Permanently" : "Move to Trash"
                ) {
                    dismiss()
                    if viewModel.deletionMode == .permanentDelete {
                        viewModel.confirmPermanentCleanup()
                    } else {
                        viewModel.executeSelectedCleanup()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.deletionMode == .permanentDelete ? .red : .green)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
