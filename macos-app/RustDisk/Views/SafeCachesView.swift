import AppKit
import SwiftUI

struct SafeCachesView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var expandedCategories = Set<String>()

    private let categoryOrder = [
        "macOS App Caches",
        "AI & Python Caches",
        "Web & Node Caches",
        "JVM & Build Caches",
        "Xcode & Homebrew Caches",
    ]

    private var filteredItems: [ScannedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.safeCacheItems }
        return viewModel.safeCacheItems.filter {
            $0.name.lowercased().contains(query)
                || $0.path.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
        }
    }

    private var groups: [CacheCategoryGroup] {
        let grouped = Dictionary(grouping: filteredItems, by: \.category)
        let ordered = categoryOrder.compactMap { category in
            grouped[category].map { CacheCategoryGroup(category: category, items: $0) }
        }
        let extra = grouped.keys
            .filter { !categoryOrder.contains($0) }
            .sorted()
            .compactMap { category in
                grouped[category].map { CacheCategoryGroup(category: category, items: $0) }
            }
        return ordered + extra
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SummaryMetricStrip(items: viewModel.safeCacheItems, recommendedItems: viewModel.recommendedCacheItems)
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group.category)) {
                        ForEach(group.items, id: \.id) { item in
                            SafeCacheRow(item: item)
                                .tag(item.id)
                        }
                    } label: {
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
            }
            .overlay {
                if viewModel.safeCacheItems.isEmpty {
                    EmptyStateView(
                        title: "No cache directories found",
                        systemImage: "sparkles",
                        message: "Run Scan Now after granting Full Disk Access if protected caches are missing."
                    )
                } else if filteredItems.isEmpty {
                    EmptyStateView(
                        title: "No matching caches",
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: "Try a different cache name, category, or path."
                    )
                }
            }
        }
        .onAppear {
            expandAllCategoriesIfNeeded()
        }
        .onChange(of: viewModel.safeCacheItems.count) { _ in
            expandAllCategoriesIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Safe Cache Purge", systemImage: "sparkles")
                .font(.headline)
            Text("Temporary app & package download files. Safe to remove; apps recreate them automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TextField("Filter caches by name or path", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Spacer()

            Button("Select All") {
                viewModel.selectedIDs.formUnion(filteredItems.map(\.id))
            }
            .buttonStyle(.bordered)

            Button("Deselect All") {
                viewModel.selectedIDs.subtract(filteredItems.map(\.id))
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
            .help("Caches and logs are rebuildable; installed tools and source code are left untouched.")
        }

    private func expansionBinding(for category: String) -> Binding<Bool> {
        Binding(
            get: { expandedCategories.contains(category) },
            set: { isExpanded in
                if isExpanded {
                    expandedCategories.insert(category)
                } else {
                    expandedCategories.remove(category)
                }
            }
        )
    }

    private func expandAllCategoriesIfNeeded() {
        guard expandedCategories.isEmpty else { return }
        expandedCategories = Set(groups.map(\.category))
    }
}

private struct CacheCategoryGroup: Identifiable {
    let category: String
    let items: [ScannedItem]

    var id: String { category }
}

private struct SafeCacheRow: View {
    let item: ScannedItem
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        HStack(spacing: 10) {
            ScannedItemRow(item: item)

            Button {
                revealInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") {
                revealInFinder()
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
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
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
