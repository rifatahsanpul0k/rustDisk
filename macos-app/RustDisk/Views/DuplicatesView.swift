import AppKit
import SwiftUI

private enum DuplicateKindFilter: String, CaseIterable, Identifiable {
    case all = "All Twins"
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
            headerBanner
            toolbar
            summaryStrip
            Divider()

            List {
                ForEach(filteredGroups, id: \.id) { group in
                    Section {
                        DuplicateGroupCard(group: group)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay { emptyState }
        }
        .onChange(of: viewModel.duplicateMinSizeBytes) { _ in
            viewModel.rescanDuplicates()
        }
    }

    private var headerBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Twin Files")
                    .font(.title2.bold())
                Text("Exact copies of the same file or folder. RustDisk automatically keeps one safe original copy for you.")
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
                TextField("Search twin files…", text: $searchText)
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

            Picker("Type", selection: $kindFilter) {
                ForEach(DuplicateKindFilter.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Menu {
                Picker("Minimum Size", selection: $viewModel.duplicateMinSizeBytes) {
                    ForEach(sizeOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Divider()
                Toggle("Always Keep 1 Safe Copy", isOn: Binding(
                    get: { !viewModel.allowDeleteAllDuplicateCopies },
                    set: { viewModel.allowDeleteAllDuplicateCopies = !$0 }
                ))
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if viewModel.activeScanningCategory == .duplicates {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCategory(.duplicates)
                } label: {
                    Label(
                        viewModel.status(for: .duplicates).isCompleted ? "Refresh" : "Scan",
                        systemImage: viewModel.status(for: .duplicates).isCompleted ? "arrow.clockwise" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan Twin Files (Cmd + R)")
            }

            Button("Auto-Select Extra Copies") {
                viewModel.autoSelectRedundantDuplicates()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(viewModel.duplicateGroups.isEmpty)

            Button("Deselect") {
                let duplicateIDs = Set(viewModel.duplicateGroups.flatMap { $0.members.map(\.id) })
                viewModel.selectedIDs.subtract(duplicateIDs)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.duplicateGroups.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            metric("Twin Groups Found", "\(viewModel.duplicateGroupCount)", .secondary)
            metric("Selected to Trash", viewModel.byteCount(viewModel.selectedDuplicatePhysicalBytes), .orange)
            metric("Safe to Free", viewModel.byteCount(viewModel.recommendedDuplicateBytes), .green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.status(for: .duplicates) {
        case .notScanned:
            VStack(spacing: 14) {
                EmptyStateView(
                    title: "Twin Files Not Scanned Yet",
                    systemImage: "square.on.square",
                    message: "Scan your Mac to find exact duplicate files and folders. One original is always kept safe."
                )
                Button {
                    viewModel.scanCategory(.duplicates)
                } label: {
                    Label("Scan Twin Files", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(viewModel.isWorking)
            }

        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Searching for Twin Files…")
                    .font(.headline)
                Text("Fingerprinting candidates with BLAKE3 quietly on Efficiency cores.")
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
            if viewModel.duplicateGroups.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        title: "No twin files found",
                        systemImage: "checkmark.seal.fill",
                        message: "No identical duplicates found above \(viewModel.byteCount(viewModel.duplicateMinSizeBytes))."
                    )
                    Button {
                        viewModel.scanCategory(.duplicates)
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } else if filteredGroups.isEmpty {
                EmptyStateView(
                    title: "No matching twin files",
                    systemImage: "line.3.horizontal.decrease.circle",
                    message: "Try clearing your search query or switching categories."
                )
            }

        case .cancelled:
            VStack(spacing: 12) {
                EmptyStateView(
                    title: "Scan Stopped",
                    systemImage: "xmark.circle",
                    message: "The scan was stopped. Existing twin files were kept."
                )
                Button {
                    viewModel.scanCategory(.duplicates)
                } label: {
                    Label("Scan Twin Files", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kindIcon)
                    .foregroundStyle(kindColor)
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("Can save \(viewModel.byteCount(group.reclaimablePhysicalBytes))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Text(group.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Divider()
                .padding(.vertical, 2)

            ForEach(group.members, id: \.id) { member in
                DuplicateMemberRow(group: group, member: member)
            }
        }
        .padding(.vertical, 4)
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
    @State private var showingInfo = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return member.path.hasPrefix(home) ? "~" + member.path.dropFirst(home.count) : member.path
    }

    private var isSelected: Bool {
        viewModel.selectedIDs.contains(member.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            // ELEMENT 1: Left (Icon + Title + Subtitle)
            Image(systemName: member.isKeepRecommended ? "checkmark.shield.fill" : "doc.on.doc")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(member.isKeepRecommended ? Color.green : Color.orange)
                .frame(width: 28, height: 28)
                .background((member.isKeepRecommended ? Color.green : Color.orange).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(member.name)
                    .font(.body.weight(.medium))
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
            Text(member.isKeepRecommended ? "Keep Safe" : "Safe to Clean")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((member.isKeepRecommended ? Color.green : Color.orange).opacity(0.12))
                .foregroundStyle(member.isKeepRecommended ? Color.green : Color.orange)
                .clipShape(Capsule())
                .lineLimit(1)

            // ELEMENT 3: Far Right (Size + ⓘ Button + Selection State)
            HStack(spacing: 8) {
                Text(viewModel.byteCount(member.physicalBytes))
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
                    memberInfoPopover
                }

                if group.kind == .duplicatePackage {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                } else if member.isKeepRecommended {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(width: 20)
                        .help("This original copy is locked and protected.")
                } else {
                    Button {
                        if isSelected {
                            viewModel.selectedIDs.remove(member.id)
                        } else {
                            viewModel.selectedIDs.insert(member.id)
                        }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Set as Keep Original", systemImage: "checkmark.shield") {
                viewModel.swapDuplicateKeep(groupID: group.id, memberID: member.id)
            }
            Button("Reveal in Finder", systemImage: "folder") {
                FinderSupport.reveal(path: member.path)
            }
            Button("Open File", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: member.path))
            }
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(member.path, forType: .string)
            }
        }
    }

    private var subtitleText: String {
        if viewModel.showProDetails {
            return shortPath
        }
        if member.isKeepRecommended {
            return "Original copy · Protected from deletion"
        } else {
            return "Extra twin copy · Safe to move to Trash"
        }
    }

    private var memberInfoPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: member.isKeepRecommended ? "checkmark.shield.fill" : "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(member.isKeepRecommended ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(member.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Copy Type", value: member.isKeepRecommended ? "Keep Original (Protected)" : "Extra Twin Copy (Safe to delete)")
                infoRow(label: "Physical Size", value: viewModel.byteCount(member.physicalBytes))
                infoRow(label: "Last Modified", value: "\(member.daysSinceModified) days ago (\(viewModel.naturalAge(member.daysSinceModified)))")
                infoRow(label: "Location", value: shortPath)
            }

            Divider()

            HStack(spacing: 10) {
                if !member.isKeepRecommended {
                    Button("Keep This Copy Instead", systemImage: "checkmark.shield") {
                        viewModel.swapDuplicateKeep(groupID: group.id, memberID: member.id)
                        showingInfo = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button("Show in Finder", systemImage: "folder") {
                    FinderSupport.reveal(path: member.path)
                    showingInfo = false
                }
                .buttonStyle(.bordered)

                Button("Open File", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: member.path))
                    showingInfo = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    showingInfo = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 460)
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
}
