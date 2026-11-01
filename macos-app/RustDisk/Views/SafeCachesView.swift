import AppKit
import SwiftUI

struct SafeCachesView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var selectedCategory = "All"
    @State private var expandedCategories = Set<String>()

    private let categoryOrder = [
        "macOS App Caches",
        "AI & Python Caches",
        "Web & Node Caches",
        "JVM & Build Caches",
        "Xcode & Homebrew Caches",
    ]

    private var availableCategories: [String] {
        ["All"] + categoryOrder
    }

    private var filteredItems: [ScannedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.safeCacheItems.filter { item in
            let matchesCategory = selectedCategory == "All" || item.category == selectedCategory
            let matchesSearch = query.isEmpty
                || item.name.lowercased().contains(query)
                || item.path.lowercased().contains(query)
                || item.category.lowercased().contains(query)
            return matchesCategory && matchesSearch
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
            headerBanner
            toolbar
            SummaryMetricStrip(items: viewModel.safeCacheItems, recommendedItems: viewModel.recommendedCacheItems)
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(groups) { group in
                    Section {
                        DisclosureGroup(isExpanded: expansionBinding(for: group.category)) {
                            ForEach(group.items, id: \.id) { item in
                                ScannedItemRow(item: item)
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
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                switch viewModel.status(for: .safeCaches) {
                case .notScanned:
                    VStack(spacing: 14) {
                        EmptyStateView(
                            title: "Junk & Temp Files Not Scanned Yet",
                            systemImage: "trash.fill",
                            message: "Scan your Mac to discover temporary app caches, browser leftovers, and package scratchpads."
                        )
                        Button {
                            viewModel.scanCategory(.safeCaches)
                        } label: {
                            Label("Scan Junk & Temp Files", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .disabled(viewModel.isWorking)
                    }

                case .scanning:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Scanning Junk & Temp Files…")
                            .font(.headline)
                        Text("Inspecting ~/Library/Caches quietly on Apple Silicon Efficiency cores.")
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
                    if viewModel.safeCacheItems.isEmpty {
                        VStack(spacing: 12) {
                            EmptyStateView(
                                title: "No junk or cache files found",
                                systemImage: "checkmark.seal.fill",
                                message: "Your Mac is clean! No unnecessary temporary cache files were detected."
                            )
                            Button {
                                viewModel.scanCategory(.safeCaches)
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if filteredItems.isEmpty {
                        EmptyStateView(
                            title: "No matching items",
                            systemImage: "line.3.horizontal.decrease.circle",
                            message: "Try clearing your search query or selecting a different category."
                        )
                    }

                case .cancelled:
                    VStack(spacing: 12) {
                        EmptyStateView(
                            title: "Scan Stopped",
                            systemImage: "xmark.circle",
                            message: "The scan was stopped. Existing files were kept."
                        )
                        Button {
                            viewModel.scanCategory(.safeCaches)
                        } label: {
                            Label("Scan Junk Files", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
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

    private var headerBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Junk & Temp Files")
                    .font(.title2.bold())
                Text("Leftover temporary files from apps and browsing. Cleaning these never deletes your personal files.")
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
                TextField("Search junk files…", text: $searchText)
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

            Picker("Category", selection: $selectedCategory) {
                ForEach(availableCategories, id: \.self) { category in
                    Text(category).tag(category)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Spacer()

            if viewModel.activeScanningCategory == .safeCaches {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCategory(.safeCaches)
                } label: {
                    Label(
                        viewModel.status(for: .safeCaches).isCompleted ? "Refresh" : "Scan",
                        systemImage: viewModel.status(for: .safeCaches).isCompleted ? "arrow.clockwise" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan Junk & Temp Files (Cmd + R)")
            }

            Button("Select Safe Junk") {
                viewModel.selectedIDs.formUnion(filteredItems.map(\.id))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(filteredItems.isEmpty)

            Button("Deselect") {
                viewModel.selectedIDs.subtract(filteredItems.map(\.id))
            }
            .buttonStyle(.bordered)
            .disabled(filteredItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
