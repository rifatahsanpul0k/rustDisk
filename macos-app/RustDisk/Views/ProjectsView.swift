import AppKit
import SwiftUI

enum ProjectEcosystemFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case webAndNode = "Web & Node"
    case pythonAndML = "Python & ML"
    case jvmAndBuild = "JVM & Build"
    case rustAndSystems = "Rust & Systems"
    case swiftAndMobile = "Swift & Mobile"

    var id: String { rawValue }
}

struct ProjectsView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var ecosystemFilter: ProjectEcosystemFilter = .all
    @State private var staleExpanded = true
    @State private var activeExpanded = true

    private let thresholds: [(String, UInt64)] = [
        ("14 Days", 14),
        ("30 Days", 30),
        ("60 Days", 60),
        ("90 Days", 90),
    ]

    private var filteredItems: [ScannedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.projectItems.filter { item in
            let matchesEcosystem = ecosystemFilter == .all || item.ecosystem == ecosystemFilter.rawValue
            let matchesSearch = query.isEmpty
                || item.name.lowercased().contains(query)
                || item.category.lowercased().contains(query)
                || item.path.lowercased().contains(query)
                || item.projectRoot.lowercased().contains(query)
            return matchesEcosystem && matchesSearch
        }
    }

    private var visibleStale: [ScannedItem] {
        filteredItems.filter { $0.activity == .stale }
    }

    private var visibleActive: [ScannedItem] {
        filteredItems.filter { $0.activity == .active }
    }

    var body: some View {
        VStack(spacing: 0) {
            filtersToolbar
            SummaryMetricStrip(
                items: viewModel.projectItems,
                recommendedItems: viewModel.recommendedStaleProjectItems
            )
            Divider()

            List(selection: $viewModel.selectedIDs) {
                DisclosureGroup(isExpanded: $staleExpanded) {
                    ForEach(visibleStale, id: \.id) { item in
                        ProjectArtifactRow(item: item)
                            .tag(item.id)
                    }
                } label: {
                    sectionHeader(
                        title: "Stale Projects — Untouched >= \(viewModel.staleThresholdDays) Days (Recommended)",
                        items: visibleStale,
                        tint: .orange
                    )
                }

                DisclosureGroup(isExpanded: $activeExpanded) {
                    ForEach(visibleActive, id: \.id) { item in
                        if viewModel.unlockActiveProjectSelection {
                            ProjectArtifactRow(item: item)
                                .tag(item.id)
                        } else {
                            ProjectArtifactRow(item: item)
                                .opacity(0.68)
                        }
                    }
                } label: {
                    sectionHeader(
                        title: "Active Projects — Modified < \(viewModel.staleThresholdDays) Days",
                        items: visibleActive,
                        tint: .green
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if viewModel.projectItems.isEmpty {
                    EmptyStateView(
                        title: "No project artifacts found",
                        systemImage: "hammer",
                        message: "RustDisk looks for manifest-backed dependencies and build folders across your developer projects."
                    )
                } else if filteredItems.isEmpty {
                    EmptyStateView(
                        title: "No matching projects",
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: "Try a different project name, artifact folder, path, or ecosystem."
                    )
                }
            }
        }
        .onChange(of: viewModel.staleThresholdDays) { _ in
            viewModel.rescanProjects()
        }
    }

    private var filtersToolbar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Label("Project Dependencies", systemImage: "hammer.fill")
                    .font(.headline)
                Spacer(minLength: 8)
                TextField("Search project, artifact, or path", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 310)
            }

                Text("Build folders from projects you have not coded in recently. Source code and Git history are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            HStack(spacing: 10) {
                Button("Select All Stale") {
                    viewModel.selectedIDs.formUnion(visibleStale.map(\.id))
                }
                .buttonStyle(.bordered)
                Button("Select All Visible") {
                    viewModel.selectedIDs.formUnion(
                        filteredItems
                            .filter { $0.activity == .stale || viewModel.unlockActiveProjectSelection }
                            .map(\.id)
                    )
                }
                .buttonStyle(.bordered)
                Button("Deselect All") {
                    viewModel.selectedIDs.subtract(viewModel.projectItems.map(\.id))
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Text("Ecosystem")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Ecosystem", selection: $ecosystemFilter) {
                    ForEach(ProjectEcosystemFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)

                Text("Stale after")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Stale threshold", selection: $viewModel.staleThresholdDays) {
                    ForEach(thresholds, id: \.1) { label, days in
                        Text(label).tag(days)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Toggle("Unlock Active Project Selection", isOn: $viewModel.unlockActiveProjectSelection)
                    .toggleStyle(.checkbox)
                    .help("Active project dependencies remain locked until explicitly unlocked.")
            }
        }
        .padding(12)
        .help("Only manifest-backed project artifacts are listed. Physical size uses APFS allocated blocks.")
    }

    private func sectionHeader(title: String, items: [ScannedItem], tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text("\(items.count)")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
            Text(byteCount(items))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func byteCount(_ items: [ScannedItem]) -> String {
        viewModel.byteCount(items.reduce(0) { $0.saturatingAdding($1.physicalBytes) })
    }
}

private struct ProjectArtifactRow: View {
    let item: ScannedItem
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    badge(item.category, color: .orange)
                    badge(item.ecosystem, color: .blue)
                }
                Text(item.activity == .stale
                     ? "Rebuildable dependencies from an older project"
                     : "Active project dependency folder — selection is locked by default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Label(item.hasGit ? "Git Tracked" : "Unversioned", systemImage: item.hasGit ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(item.hasGit ? .green : .orange)
                    badge("Restore: \(item.restoreHint)", color: .purple)
                    Text(viewModel.naturalAge(item.daysSinceModified))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.naturalAge(item.daysSinceModified))
                    .font(.caption)
                    .foregroundStyle(item.activity == .stale ? .orange : .green)
                    .monospacedDigit()
                if item.activity == .active {
                    Text("Active")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Text(viewModel.byteCount(item.physicalBytes))
                .font(.system(.body, design: .monospaced))
                .bold()
                .frame(width: 94, alignment: .trailing)

            Button {
                reveal(item.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal artifact in Finder")

            Menu {
                projectActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Project actions")
        }
        .padding(.vertical, 5)
        .help("Modified \(item.daysSinceModified) days ago\n\(item.path)")
        .contextMenu {
            projectActions
        }
    }

    @ViewBuilder
    private var projectActions: some View {
        Button("Reveal Artifact in Finder", systemImage: "folder") {
            reveal(item.path)
        }
        Button("Reveal Project Folder in Finder", systemImage: "folder.badge.gearshape") {
            reveal(item.projectRoot)
        }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") {
            copy(item.path)
        }
        Button("Copy Restore Command", systemImage: "terminal") {
            copy(item.restoreHint)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private func reveal(_ path: String) {
        FinderSupport.reveal(path: path)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
