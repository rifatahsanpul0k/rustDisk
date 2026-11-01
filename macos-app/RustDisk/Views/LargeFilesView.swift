import AppKit
import SwiftUI

private enum LargeFileCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
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
            filtersToolbar
            SummaryMetricStrip(
                items: viewModel.largeFileItems,
                recommendedItems: viewModel.recommendedInstallerItems
            )
            Divider()
            largeFileList
        }
        .onChange(of: viewModel.largeFileThresholdBytes) { _ in
            viewModel.rescanLargeFiles()
        }
        .onChange(of: viewModel.hideLargeFileDevCaches) { _ in
            viewModel.rescanLargeFiles()
        }
    }

    private var largeFileList: some View {
        List(selection: $viewModel.selectedIDs) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items, id: \.id) { item in
                        largeFileRow(item)
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private func largeFileRow(_ item: ScannedItem) -> some View {
        if item.risk == .highRiskCli {
            LargeFileRow(item: item)
        } else {
            LargeFileRow(item: item)
                .tag(item.id)
        }
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
            Text(viewModel.byteCount(groupPhysicalBytes(group)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.largeFileItems.isEmpty {
            EmptyStateView(
                title: "No large files found",
                systemImage: "externaldrive",
                message: "RustDisk scans for files consuming physical APFS blocks while avoiding application bundles and development internals."
            )
        } else if filteredItems.isEmpty {
            EmptyStateView(
                title: "No matching large files",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "Try a different size threshold, category, search term, or scope."
            )
        }
    }

    private func groupPhysicalBytes(_ group: LargeFileGroup) -> UInt64 {
        group.items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    private var filtersToolbar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Label("Global Large File Finder", systemImage: "externaldrive.fill.badge.timemachine")
                    .font(.headline)
                Text("Standalone files you can review: installers, archives, models, media, and virtual disks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                TextField("Search filename, extension, category, or path", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)

                Spacer()

                Button("Select Installers") {
                    let installerIDs = filteredItems
                        .filter { isInstaller($0) && $0.risk != .highRiskCli }
                        .map(\.id)
                    viewModel.selectedIDs.formUnion(installerIDs)
                }
                .buttonStyle(.bordered)
                .help("Select visible .dmg, .pkg, .mpkg, .iso, .xip, and .ipsw files.")

                Button("Select All Visible") {
                    viewModel.selectedIDs.formUnion(
                        filteredItems.filter { $0.risk != .highRiskCli }.map(\.id)
                    )
                }
                .buttonStyle(.bordered)

                Button("Deselect All") {
                    viewModel.selectedIDs.subtract(filteredItems.map(\.id))
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Text("Minimum physical size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Minimum size", selection: $viewModel.largeFileThresholdBytes) {
                    ForEach(thresholds, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 105)

                Text("Category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Category", selection: $categoryFilter) {
                    ForEach(LargeFileCategoryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 195)

                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $sortOrder) {
                    ForEach(LargeFileSort.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)

                Toggle("Hide Dev Caches & Package Internals", isOn: $viewModel.hideLargeFileDevCaches)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(filteredItems.count) file(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .help("Physical size uses APFS allocated blocks. Sparse files show physical and logical sizes separately.")
    }

    private func isInstaller(_ item: ScannedItem) -> Bool {
        let extensionName = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        return ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw"].contains(extensionName)
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

    private var parentPath: String {
        URL(fileURLWithPath: item.path).deletingLastPathComponent().path
    }

    private var isSparse: Bool {
        item.logicalBytes > item.physicalBytes.saturatingMultiplying(2)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: categoryIcon)
                .foregroundStyle(categoryColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    badge(item.category, color: categoryColor)
                    badge(riskLabel, color: riskColor)
                }

                Text(parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(viewModel.naturalAge(item.daysSinceModified))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if isSparse {
                        Text("Sparse: \(viewModel.byteCount(item.physicalBytes)) physical / \(viewModel.byteCount(item.logicalBytes)) logical")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    } else {
                        Text("Logical \(viewModel.byteCount(item.logicalBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.byteCount(item.physicalBytes))
                    .font(.system(.body, design: .monospaced))
                    .bold()
                    .monospacedDigit()
                Text("physical")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 105, alignment: .trailing)

            if item.risk == .highRiskCli {
                Button("Terminal Packages") {
                    viewModel.openTerminalPackagesForProtectedItem()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Docker.raw and other virtual disks must be managed with Terminal Packages.")
            } else {
                Button {
                    revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }

            Menu {
                fileActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Large file actions")
        }
        .padding(.vertical, 5)
        .opacity(item.risk == .highRiskCli ? 0.78 : 1)
        .help("Modified \(item.daysSinceModified) days ago\n\(item.path)")
        .contextMenu {
            fileActions
        }
    }

    @ViewBuilder
    private var fileActions: some View {
        if item.risk == .highRiskCli {
            Button("Open Terminal Packages", systemImage: "terminal") {
                viewModel.openTerminalPackagesForProtectedItem()
            }
            Text("Protected virtual disks cannot be deleted directly.")
        } else {
            Button("Reveal in Finder", systemImage: "folder") {
                revealInFinder()
            }
            Button("Open Parent Folder", systemImage: "folder.badge.gearshape") {
                openParentFolder()
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                copyPath()
            }
            Divider()
            Button(viewModel.selectedIDs.contains(item.id) ? "Deselect" : "Select") {
                if viewModel.selectedIDs.contains(item.id) {
                    viewModel.selectedIDs.remove(item.id)
                } else {
                    viewModel.selectedIDs.insert(item.id)
                }
            }
        }
    }

    private func revealInFinder() {
        FinderSupport.reveal(path: item.path)
    }

    private func openParentFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: parentPath, isDirectory: true))
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
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
        case "Virtual Machines & Disks": return .red
        default: return .secondary
        }
    }

    private var riskLabel: String {
        switch item.risk {
        case .safe: return "Safe"
        case .rebuildable: return "Review"
        case .highRiskCli: return "Protected VM"
        }
    }

    private var riskColor: Color {
        switch item.risk {
        case .safe: return .green
        case .rebuildable: return .orange
        case .highRiskCli: return .red
        }
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }

    func saturatingMultiplying(_ other: UInt64) -> UInt64 {
        multipliedReportingOverflow(by: other).overflow ? UInt64.max : self * other
    }
}
