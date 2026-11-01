import AppKit
import SwiftUI

private enum LargeFileCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All Categories"
    case installers = "Disk Images & Installers"
    case archives = "Archives & Backups"
    case ai = "AI Models & Datasets"
    case media = "Video & Audio Media"
    case virtualMachines = "Virtual Machines & Disks"
    case other = "Other Large Files"

    var id: String { rawValue }
}

private enum LargeFileSort: String, CaseIterable, Identifiable {
    case largestPhysical = "Largest Physical Size"
    case largestLogical = "Largest Logical Size"
    case oldest = "Oldest First"
    case newest = "Newest First"

    var id: String { rawValue }
}

struct LargeFilesView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var categoryFilter: LargeFileCategoryFilter = .all
    @State private var sortOrder: LargeFileSort = .largestPhysical

    private let thresholds: [(String, UInt64)] = [
        ("50 MB", 50 * 1024 * 1024),
        ("100 MB", 100 * 1024 * 1024),
        ("250 MB", 250 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
        ("1 GB", 1 * 1024 * 1024 * 1024),
        ("5 GB", 5 * 1024 * 1024 * 1024),
    ]

    private var filteredItems: [ScannedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = viewModel.largeFileItems.filter { item in
            let matchesCategory = categoryFilter == .all || item.category == categoryFilter.rawValue
            let matchesSearch = query.isEmpty
                || item.name.lowercased().contains(query)
                || item.path.lowercased().contains(query)
                || item.category.lowercased().contains(query)
                || URL(fileURLWithPath: item.path).pathExtension.lowercased().contains(query)
            return matchesCategory && matchesSearch
        }

        return filtered.sorted { left, right in
            switch sortOrder {
            case .largestPhysical:
                return left.physicalBytes > right.physicalBytes
            case .largestLogical:
                return left.logicalBytes > right.logicalBytes
            case .oldest:
                return left.daysSinceModified > right.daysSinceModified
            case .newest:
                return left.daysSinceModified < right.daysSinceModified
            }
        }
    }

    private var groups: [LargeFileGroup] {
        let grouped = Dictionary(grouping: filteredItems, by: \.category)
        let orderedCategories = LargeFileCategoryFilter.allCases
            .filter { $0 != .all }
            .map(\.rawValue)
        let ordered = orderedCategories.compactMap { category in
            grouped[category].map { LargeFileGroup(category: category, items: $0) }
        }
        let extra = grouped.keys
            .filter { !orderedCategories.contains($0) }
            .sorted()
            .compactMap { category in
                grouped[category].map { LargeFileGroup(category: category, items: $0) }
            }
        return ordered + extra
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBanner
            toolbar
            SummaryMetricStrip(
                items: viewModel.largeFileItems,
                recommendedItems: viewModel.recommendedInstallerItems
            )
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items, id: \.id) { item in
                            if item.risk == .highRiskCli {
                                LargeFileRow(item: item)
                                    .opacity(0.7)
                            } else {
                                LargeFileRow(item: item)
                                    .tag(item.id)
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                switch viewModel.status(for: .largeFiles) {
                case .notScanned:
                    VStack(spacing: 14) {
                        EmptyStateView(
                            title: "Big Files Not Scanned Yet",
                            systemImage: "externaldrive.fill",
                            message: "Scan your Mac to find huge installers, videos, and archives taking up the most room."
                        )
                        Button {
                            viewModel.scanCategory(.largeFiles)
                        } label: {
                            Label("Scan Big Files", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.large)
                        .disabled(viewModel.isWorking)
                    }

                case .scanning:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Hunting Large Files…")
                            .font(.headline)
                        Text("Scanning files above \(viewModel.byteCount(viewModel.largeFileThresholdBytes)) across your drive.")
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
                    if viewModel.largeFileItems.isEmpty {
                        VStack(spacing: 12) {
                            EmptyStateView(
                                title: "No large files found",
                                systemImage: "checkmark.seal.fill",
                                message: "No files exceed your minimum size threshold (\(viewModel.byteCount(viewModel.largeFileThresholdBytes)))."
                            )
                            Button {
                                viewModel.scanCategory(.largeFiles)
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if filteredItems.isEmpty {
                        EmptyStateView(
                            title: "No matching files",
                            systemImage: "line.3.horizontal.decrease.circle",
                            message: "Try clearing your search query or selecting a different category."
                        )
                    }

                case .cancelled:
                    VStack(spacing: 12) {
                        EmptyStateView(
                            title: "Scan Stopped",
                            systemImage: "xmark.circle",
                            message: "The scan was stopped. Existing results were kept."
                        )
                        Button {
                            viewModel.scanCategory(.largeFiles)
                        } label: {
                            Label("Scan Big Files", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
            }
        }
        .onChange(of: viewModel.largeFileThresholdBytes) { _ in
            viewModel.rescanLargeFiles()
        }
        .onChange(of: viewModel.hideLargeFileDevCaches) { _ in
            viewModel.rescanLargeFiles()
        }
    }

    private var headerBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Big Files")
                    .font(.title2.bold())
                Text("Large downloads, movie files, and old app installers taking up the most room on your Mac.")
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
                TextField("Search big files…", text: $searchText)
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

            Picker("Category", selection: $categoryFilter) {
                ForEach(LargeFileCategoryFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            Menu {
                Picker("Minimum Size", selection: $viewModel.largeFileThresholdBytes) {
                    ForEach(thresholds, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Picker("Sort Order", selection: $sortOrder) {
                    ForEach(LargeFileSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Divider()
                Toggle("Hide Developer Caches", isOn: $viewModel.hideLargeFileDevCaches)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if viewModel.activeScanningCategory == .largeFiles {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCategory(.largeFiles)
                } label: {
                    Label(
                        viewModel.status(for: .largeFiles).isCompleted ? "Refresh" : "Scan",
                        systemImage: viewModel.status(for: .largeFiles).isCompleted ? "arrow.clockwise" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan Big Files (Cmd + R)")
            }

            Button("Select Safe Installers") {
                let installers = filteredItems.filter {
                    $0.category == "Disk Images & Installers" && $0.risk != .highRiskCli
                }
                viewModel.selectedIDs.formUnion(installers.map(\.id))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(filteredItems.isEmpty)

            Button("Deselect") {
                viewModel.selectedIDs.subtract(viewModel.largeFileItems.map(\.id))
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.largeFileItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func groupHeader(_ group: LargeFileGroup) -> some View {
        HStack {
            Text(group.category)
                .font(.headline)
            Text("\(group.items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12))
                .clipShape(Capsule())
            Spacer()
            Text(viewModel.byteCount(group.items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct LargeFileGroup: Identifiable {
    let category: String
    let items: [ScannedItem]

    var id: String { category }
}

private struct LargeFileRow: View {
    let item: ScannedItem
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingInfo = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
    }

    var body: some View {
        HStack(spacing: 12) {
            // ELEMENT 1: Left (Icon + Bold Friendly Title + 1-Line Subtitle)
            Image(systemName: categoryIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(categoryColor)
                .frame(width: 30, height: 30)
                .background(categoryColor.opacity(0.12))
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
            safetyPill

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
                    fileInfoPopover
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if item.risk != .highRiskCli {
                Button("Reveal in Finder", systemImage: "folder") {
                    revealInFinder()
                }
                Button("Open File", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    copyPath()
                }
            } else {
                Button("Open Terminal Packages", systemImage: "terminal") {
                    viewModel.openTerminalPackagesForProtectedItem()
                }
            }
        }
    }

    private var subtitleText: String {
        if viewModel.showProDetails {
            return shortPath
        }
        switch item.category {
        case "Disk Images & Installers":
            return "App installer · Safe to remove"
        case "Archives & Backups":
            return "Compressed archive · Untouched \(viewModel.naturalAge(item.daysSinceModified))"
        case "Video & Audio Media":
            return "Media file · Untouched \(viewModel.naturalAge(item.daysSinceModified))"
        case "AI Models & Datasets":
            return "Machine learning model or dataset"
        case "Virtual Machines & Disks":
            return "Virtual machine disk · Protected"
        default:
            return "Modified \(viewModel.naturalAge(item.daysSinceModified))"
        }
    }

    private var safetyPill: some View {
        let (label, color) = pillDetails
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private var pillDetails: (String, Color) {
        if item.category == "Disk Images & Installers" || item.risk == .safe {
            return ("Safe to Clean", .green)
        } else if item.risk == .rebuildable {
            return ("Can Be Rebuilt", .orange)
        } else if item.risk == .highRiskCli {
            return ("Keep Safe", .secondary)
        } else {
            return ("Review File", .blue)
        }
    }

    private var categoryIcon: String {
        switch item.category {
        case "Disk Images & Installers": return "shippingbox.fill"
        case "Archives & Backups": return "archivebox.fill"
        case "AI Models & Datasets": return "brain.head.profile"
        case "Video & Audio Media": return "play.rectangle.fill"
        case "Virtual Machines & Disks": return "desktopcomputer"
        default: return "doc.fill"
        }
    }

    private var categoryColor: Color {
        switch item.category {
        case "Disk Images & Installers": return .green
        case "Archives & Backups": return .blue
        case "AI Models & Datasets": return .purple
        case "Video & Audio Media": return .pink
        case "Virtual Machines & Disks": return .secondary
        default: return .secondary
        }
    }

    private var fileInfoPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: categoryIcon)
                    .font(.title2)
                    .foregroundStyle(categoryColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Safety Status", value: pillDetails.0)
                infoRow(label: "Physical APFS Size", value: viewModel.byteCount(item.physicalBytes))
                if item.logicalBytes != item.physicalBytes {
                    infoRow(label: "Logical Size", value: viewModel.byteCount(item.logicalBytes))
                }
                infoRow(label: "Last Modified", value: "\(item.daysSinceModified) days ago (\(viewModel.naturalAge(item.daysSinceModified)))")
                infoRow(label: "Location", value: shortPath)
            }

            Divider()

            HStack(spacing: 10) {
                if item.risk != .highRiskCli {
                    Button("Show in Finder", systemImage: "folder") {
                        revealInFinder()
                        showingInfo = false
                    }
                    .buttonStyle(.bordered)

                    Button("Open File", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                        showingInfo = false
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Manage in Apps & Dev Tools", systemImage: "terminal") {
                        showingInfo = false
                        viewModel.openTerminalPackagesForProtectedItem()
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

    private func revealInFinder() {
        FinderSupport.reveal(path: item.path)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
