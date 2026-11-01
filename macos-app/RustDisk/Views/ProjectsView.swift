import AppKit
import SwiftUI

enum ProjectEcosystemFilter: String, CaseIterable, Identifiable {
    case all = "All Ecosystems"
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
            headerBanner
            toolbar
            SummaryMetricStrip(
                items: viewModel.projectItems,
                recommendedItems: viewModel.recommendedStaleProjectItems
            )
            Divider()

            List(selection: $viewModel.selectedIDs) {
                Section {
                    DisclosureGroup(isExpanded: $staleExpanded) {
                        ForEach(visibleStale, id: \.id) { item in
                            ProjectArtifactRow(item: item)
                                .tag(item.id)
                        }
                    } label: {
                        sectionHeader(
                            title: "Old Projects — Untouched >= \(viewModel.staleThresholdDays) Days (Safe to Clean)",
                            items: visibleStale,
                            tint: .orange
                        )
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $activeExpanded) {
                        ForEach(visibleActive, id: \.id) { item in
                            if viewModel.unlockActiveProjectSelection {
                                ProjectArtifactRow(item: item)
                                    .tag(item.id)
                            } else {
                                ProjectArtifactRow(item: item)
                                    .opacity(0.65)
                            }
                        }
                    } label: {
                        sectionHeader(
                            title: "Active Projects — Modified Recently (Locked for Safety)",
                            items: visibleActive,
                            tint: .blue
                        )
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                switch viewModel.status(for: .projects) {
                case .notScanned:
                    VStack(spacing: 14) {
                        EmptyStateView(
                            title: "Coding Projects Not Scanned Yet",
                            systemImage: "hammer.fill",
                            message: "Scan your Mac to find old dependency folders (node_modules, target, .venv) from projects you haven't opened lately."
                        )
                        Button {
                            viewModel.scanCategory(.projects)
                        } label: {
                            Label("Scan Old Coding Folders", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                        .disabled(viewModel.isWorking)
                    }

                case .scanning:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Analyzing Coding Projects…")
                            .font(.headline)
                        Text("Checking project manifests while leaving your code and Git history 100% untouched.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(role: .cancel) {
                            viewModel.cancelScan()
                        } label: {
                            Label("Stop Scan", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                case .completed:
                    if viewModel.projectItems.isEmpty {
                        VStack(spacing: 12) {
                            EmptyStateView(
                                title: "No coding projects found",
                                systemImage: "checkmark.seal.fill",
                                message: "No heavy build folders or unused dependencies detected in your home directory."
                            )
                            Button {
                                viewModel.scanCategory(.projects)
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if filteredItems.isEmpty {
                        EmptyStateView(
                            title: "No matching projects",
                            systemImage: "line.3.horizontal.decrease.circle",
                            message: "Try clearing your search query or switching ecosystems."
                        )
                    }

                case .cancelled:
                    VStack(spacing: 12) {
                        EmptyStateView(
                            title: "Scan Stopped",
                            systemImage: "xmark.circle",
                            message: "The scan was stopped. Existing project results were kept."
                        )
                        Button {
                            viewModel.scanCategory(.projects)
                        } label: {
                            Label("Scan Coding Folders", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
        }
        .onChange(of: viewModel.staleThresholdDays) { _ in
            viewModel.rescanProjects()
        }
    }

    private var headerBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Old Coding Folders")
                    .font(.title2.bold())
                Text("Heavy helper folders from old coding projects you haven't opened lately. Your actual code and Git history are never touched.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search projects…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .frame(maxWidth: 240)

            Picker("Ecosystem", selection: $ecosystemFilter) {
                ForEach(ProjectEcosystemFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Menu {
                Picker("Consider Stale After", selection: $viewModel.staleThresholdDays) {
                    ForEach(thresholds, id: \.1) { label, days in
                        Text(label).tag(days)
                    }
                }
                Divider()
                Toggle("Unlock Active Projects", isOn: $viewModel.unlockActiveProjectSelection)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if viewModel.activeScanningCategory == .projects {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCategory(.projects)
                } label: {
                    Label(
                        viewModel.status(for: .projects).isCompleted ? "Refresh" : "Scan",
                        systemImage: viewModel.status(for: .projects).isCompleted ? "arrow.clockwise" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan Old Coding Folders (Cmd + R)")
            }

            Button("Select Old Projects") {
                viewModel.selectedIDs.formUnion(visibleStale.map(\.id))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(visibleStale.isEmpty)

            Button("Deselect") {
                viewModel.selectedIDs.subtract(viewModel.projectItems.map(\.id))
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.projectItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            Text(viewModel.byteCount(items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProjectArtifactRow: View {
    let item: ScannedItem
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingInfo = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
    }

    private var isStale: Bool {
        item.activity == .stale
    }

    var body: some View {
        HStack(spacing: 12) {
            // ELEMENT 1: Left (Icon + Bold Friendly Title + 1-Line Subtitle)
            Image(systemName: isStale ? "hammer.fill" : "lock.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isStale ? Color.orange : Color.secondary)
                .frame(width: 30, height: 30)
                .background((isStale ? Color.orange : Color.secondary).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            // ELEMENT 2: Middle/Right (ONE Semantic Safety Pill)
            Text(isStale ? "Can Be Rebuilt" : "Keep Safe")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isStale ? Color.orange : Color.secondary).opacity(0.12))
                .foregroundStyle(isStale ? Color.orange : Color.secondary)
                .clipShape(Capsule())
                .lineLimit(1)

            // ELEMENT 3: Far Right (Formatted Size + ⓘ Button)
            HStack(spacing: 8) {
                Text(viewModel.byteCount(item.physicalBytes))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)

                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
                    projectInfoPopover
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Reveal Artifact in Finder", systemImage: "folder") {
                FinderSupport.reveal(path: item.path)
            }
            Button("Reveal Project Root", systemImage: "folder.badge.gearshape") {
                FinderSupport.reveal(path: item.projectRoot)
            }
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") {
                copy(item.path)
            }
            if !item.restoreHint.isEmpty {
                Button("Copy Rebuild Command (\(item.restoreHint))", systemImage: "terminal") {
                    copy(item.restoreHint)
                }
            }
        }
    }

    private var subtitleText: String {
        if viewModel.showProDetails {
            return "\(shortPath) · \(item.restoreHint)"
        }
        if isStale {
            return "Untouched for \(viewModel.naturalAge(item.daysSinceModified)) · Your code stays safe"
        } else {
            return "Active project · Selection locked for safety"
        }
    }

    private var projectInfoPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "hammer.fill")
                    .font(.title2)
                    .foregroundStyle(isStale ? Color.orange : Color.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(item.ecosystem) · \(item.category)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Safety Status", value: isStale ? "Can Be Rebuilt (Safe to delete; source code untouched)" : "Active Project (Locked for safety)")
                infoRow(label: "Rebuild Command", value: item.restoreHint.isEmpty ? "Recreated automatically upon build" : item.restoreHint)
                infoRow(label: "Git Version Control", value: item.hasGit ? "Tracked with Git (Safe)" : "No Git repository found")
                infoRow(label: "Physical Space", value: viewModel.byteCount(item.physicalBytes))
                infoRow(label: "Last Modified", value: "\(item.daysSinceModified) days ago (\(viewModel.naturalAge(item.daysSinceModified)))")
                infoRow(label: "Location", value: shortPath)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Show in Finder", systemImage: "folder") {
                    FinderSupport.reveal(path: item.path)
                    showingInfo = false
                }
                .buttonStyle(.bordered)

                if !item.restoreHint.isEmpty {
                    Button("Copy Rebuild", systemImage: "terminal") {
                        copy(item.restoreHint)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Done") {
                    showingInfo = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
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
