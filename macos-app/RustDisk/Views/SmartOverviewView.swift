import SwiftUI

struct SmartOverviewView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                bentoGrid
            }
            .padding(18)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Smart Overview", systemImage: "sparkles.rectangle.stack.fill")
                        .font(.headline)
                    Text("Recommended Safe Reclaim")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(viewModel.recommendedReclaimGB)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                    Text("Caches, stale project dependencies, and disk-image installers that can be removed without touching source code or Git history.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.green.gradient)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.selectRecommendedForReview()
                } label: {
                    Label("Review Recommended Items", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(viewModel.isWorking || viewModel.isScanning || viewModel.recommendedReclaimBytes == 0)

                Button("Reset to Recommended") {
                    viewModel.resetToRecommended()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.green.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1)
                }
        )
    }

    private var bentoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            summaryCard(
                title: "Safe Caches",
                icon: "sparkles",
                color: .green,
                items: viewModel.safeCacheItems,
                summary: "Temporary app and package downloads. Apps recreate them automatically.",
                include: Binding(
                    get: { viewModel.smartCleanIncludeCaches },
                    set: { viewModel.smartCleanIncludeCaches = $0 }
                ),
                tab: .safeCaches
            )
            summaryCard(
                title: "Stale vs. Active Projects",
                icon: "hammer.fill",
                color: .orange,
                items: viewModel.staleProjects,
                summary: "Build folders from projects you have not coded in recently. Source and Git history stay untouched.",
                include: Binding(
                    get: { viewModel.smartCleanIncludeStaleProjects },
                    set: { viewModel.smartCleanIncludeStaleProjects = $0 }
                ),
                tab: .projects
            )
            summaryCard(
                title: "Terminal Packages & Docker",
                icon: "terminal.fill",
                color: .purple,
                items: [],
                summary: "CLI tools and runtimes installed outside the Applications folder. Review these separately.",
                include: Binding(
                    get: { viewModel.smartCleanIncludeTerminalPackages },
                    set: { viewModel.smartCleanIncludeTerminalPackages = $0 }
                ),
                tab: .packages,
                packageCount: viewModel.terminalPackages.count,
                packageBytes: viewModel.terminalPackages.reduce(0) { $0.saturatingAdding($1.physicalBytes) },
                toggleEnabled: false
            )
            summaryCard(
                title: "Large Files",
                icon: "externaldrive.fill.badge.timemachine",
                color: .blue,
                items: viewModel.largeFileItems,
                summary: "Standalone installers, archives, models, media, and virtual disks. Inspect before removing.",
                include: Binding(
                    get: { viewModel.smartCleanIncludeInstallers },
                    set: { viewModel.smartCleanIncludeInstallers = $0 }
                ),
                tab: .largeFiles
            )
            duplicateSummaryCard
        }
    }

    private var duplicateSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Duplicates", systemImage: "square.on.square")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text(viewModel.byteCount(viewModel.recommendedDuplicateBytes))
                    .font(.system(.headline, design: .monospaced))
            }
            Text("\(viewModel.duplicateGroupCount) group\(viewModel.duplicateGroupCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Identical files, folders, and redundant runtimes. One original stays protected in every group.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Open Duplicates") {
                    viewModel.selectedTab = .duplicates
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                Spacer()
                Text("Remove duplicates from the Duplicates page only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(15)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private func summaryCard(
        title: String,
        icon: String,
        color: Color,
        items: [ScannedItem],
        summary: String,
        include: Binding<Bool>,
        tab: NavigationTab,
        packageCount: Int? = nil,
        packageBytes: UInt64? = nil,
        toggleEnabled: Bool = true
    ) -> some View {
        let count = packageCount ?? items.count
        let bytes = packageBytes ?? items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                Text(viewModel.byteCount(bytes))
                    .font(.system(.headline, design: .monospaced))
            }
            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if toggleEnabled {
                    Toggle("Include in Smart Clean", isOn: include)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                } else {
                    Label("CLI actions stay separate", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Inspect Details →") {
                    viewModel.selectedTab = tab
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(15)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }
}
