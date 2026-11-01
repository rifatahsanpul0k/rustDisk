import AppKit
import SwiftUI

private enum DuplicateKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case files = "Duplicate Files"
    case folders = "Duplicate Folders"
    case packages = "Duplicate Packages"

    var id: String { rawValue }
}

struct DuplicatesView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var kindFilter: DuplicateKindFilter = .all

    private let sizeOptions: [(String, UInt64)] = [
        ("1 MB", 1 * 1024 * 1024),
        ("10 MB", 10 * 1024 * 1024),
        ("50 MB", 50 * 1024 * 1024),
        ("100 MB", 100 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
    ]

    private var filteredGroups: [DuplicateGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.duplicateGroups.filter { group in
            let matchesKind: Bool
            switch kindFilter {
            case .all: matchesKind = true
            case .files: matchesKind = group.kind == .duplicateFile
            case .folders: matchesKind = group.kind == .duplicateFolder
            case .packages: matchesKind = group.kind == .duplicatePackage
            }
            let matchesSearch = query.isEmpty
                || group.title.lowercased().contains(query)
                || group.subtitle.lowercased().contains(query)
                || group.category.lowercased().contains(query)
                || group.members.contains {
                    $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
                }
            return matchesKind && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            summaryStrip
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(filteredGroups, id: \.id) { group in
                    DuplicateGroupCard(group: group)
                }
            }
            .overlay { emptyState }
        }
        .onChange(of: viewModel.duplicateMinSizeBytes) { _ in
            viewModel.rescanDuplicates()
        }
    }

    private var toolbar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Label("Duplicates", systemImage: "square.on.square")
                    .font(.headline)
                Text("Remove files and folders here. Package versions are shown for review and stay package-managed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                TextField("Search name or path", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 260)
            }

            HStack(spacing: 10) {
                Picker("Show", selection: $kindFilter) {
                    ForEach(DuplicateKindFilter.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                Picker("Minimum size", selection: $viewModel.duplicateMinSizeBytes) {
                    ForEach(sizeOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)

                Toggle("Always Keep 1 Copy", isOn: Binding(
                    get: { !viewModel.allowDeleteAllDuplicateCopies },
                    set: { viewModel.allowDeleteAllDuplicateCopies = !$0 }
                ))
                .toggleStyle(.checkbox)

                Spacer()

                Button("Auto-Select Redundant Copies") {
                    viewModel.autoSelectRedundantDuplicates()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.duplicateGroups.isEmpty)

                Button("Deselect All") {
                    let duplicateIDs = Set(viewModel.duplicateGroups.flatMap { $0.members.map(\.id) })
                    viewModel.selectedIDs.subtract(duplicateIDs)
                }
                .buttonStyle(.bordered)

                Button("Review Cleanup (\(viewModel.selectedDuplicateCount))") {
                    viewModel.requestDuplicateCleanup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedDuplicateCount == 0 || viewModel.isWorking || viewModel.isScanning)
            }
        }
        .padding(12)
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            metric("Duplicate Groups Found", "\(viewModel.duplicateGroupCount)", .secondary)
            metric("Selected to Reclaim", viewModel.byteCount(viewModel.selectedDuplicatePhysicalBytes), .orange)
            metric("Smart Safe Reclaim", viewModel.byteCount(viewModel.recommendedDuplicateBytes), .green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.duplicateGroups.isEmpty {
            EmptyStateView(
                title: "No duplicates found",
                systemImage: "checkmark.seal",
                message: "Run Scan Now to compare standalone files, folders, and package runtimes without touching protected system or development trees."
            )
        } else if filteredGroups.isEmpty {
            EmptyStateView(
                title: "No matching duplicate groups",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "Try a different kind, minimum size, or search term."
            )
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        Section {
            ForEach(group.members, id: \.id) { member in
                if member.isKeepRecommended || group.kind == .duplicatePackage {
                    DuplicateMemberRow(group: group, member: member)
                } else {
                    DuplicateMemberRow(group: group, member: member)
                        .tag(member.id)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: kindIcon)
                    .foregroundStyle(kindColor)
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                badge(group.category, color: kindColor)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Reclaim \(viewModel.byteCount(group.reclaimablePhysicalBytes))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
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

    private var kindIcon: String {
        switch group.kind {
        case .duplicateFile: return "doc.on.doc.fill"
        case .duplicateFolder: return "folder.fill.badge.person.crop"
        case .duplicatePackage: return "shippingbox.fill"
        }
    }

    private var kindColor: Color {
        switch group.kind {
        case .duplicateFile: return .blue
        case .duplicateFolder: return .orange
        case .duplicatePackage: return .purple
        }
    }
}

private struct DuplicateMemberRow: View {
    let group: DuplicateGroup
    let member: DuplicateMember
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return member.path.hasPrefix(home) ? "~" + member.path.dropFirst(home.count) : member.path
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: member.isKeepRecommended ? "checkmark.shield.fill" : "doc.on.doc")
                .foregroundStyle(member.isKeepRecommended ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(member.name)
                        .font(.headline)
                        .lineLimit(1)
                    badge(member.isKeepRecommended ? "Keep Original" : "Redundant Copy", color: member.isKeepRecommended ? .green : .orange)
                    badge(member.sourceLabel, color: .secondary)
                }
                HStack(spacing: 8) {
                    Text(shortPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(viewModel.naturalAge(member.daysSinceModified))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(viewModel.byteCount(member.physicalBytes))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if group.kind == .duplicatePackage {
                Label("Package-managed", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if member.isKeepRecommended {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: viewModel.selectedIDs.contains(member.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.selectedIDs.contains(member.id) ? .orange : .secondary)
            }

            Menu {
                memberActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 5)
        .contextMenu { memberActions }
    }

    @ViewBuilder
    private var memberActions: some View {
        Button("Set as Keep Original", systemImage: "checkmark.shield") {
            viewModel.swapDuplicateKeep(groupID: group.id, memberID: member.id)
        }
        Button("Reveal in Finder", systemImage: "folder") {
            FinderSupport.reveal(path: member.path)
        }
        Button("Quick Look / Open", systemImage: "eye") {
            NSWorkspace.shared.open(URL(fileURLWithPath: member.path))
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(member.path, forType: .string)
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
}
