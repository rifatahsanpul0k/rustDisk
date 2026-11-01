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
    @State private var hoveredTab: NavigationTab?

    var body: some View {
        HStack(spacing: 0) {
            // Left Custom Dark Sidebar
            VStack(alignment: .leading, spacing: 18) {
                // Window Titlebar Brand
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.blue)
                    Text("RustDisk")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Dashboard Section
                VStack(alignment: .leading, spacing: 3) {
                    Text("DASHBOARD")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)

                    sidebarItem(.smartOverview)
                }

                // Audit Modules Section
                VStack(alignment: .leading, spacing: 3) {
                    Text("AUDIT MODULES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)

                    ForEach(NavigationTab.allCases.dropFirst()) { tab in
                        sidebarItem(tab)
                    }
                }

                Spacer()

                // Thermal state badge
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.thermalBadgeColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.thermalBadgeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .help("Real-time Apple Silicon QoS & thermal pacing status.")
            }
            .frame(width: 240)
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            // Right Detail Canvas
            VStack(spacing: 0) {
                controlBar
                if viewModel.isScanning {
                    scanProgressBanner
                }
                StorageHeaderView()
                    .environmentObject(viewModel)
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
            .background(Color(red: 0.10, green: 0.10, blue: 0.11))
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

    private func sidebarItem(_ tab: NavigationTab) -> some View {
        let isSelected = viewModel.selectedTab == tab
        let isHovered = hoveredTab == tab
        let isActivelyScanning = viewModel.activeScanningCategory == tab || (viewModel.activeScanningCategory == .smartOverview && (tab == .safeCaches || tab == .projects))

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectedTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary))
                    .frame(width: 18)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer()

                if isActivelyScanning {
                    ProgressView()
                        .controlSize(.mini)
                } else if case let .completed(count, bytes, _) = viewModel.status(for: tab), count > 0 {
                    Text(viewModel.byteCount(bytes))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.blue : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
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
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
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
        .background(Color.accentColor.opacity(0.12))
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
            .background(Color.orange.opacity(0.12))
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
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
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
