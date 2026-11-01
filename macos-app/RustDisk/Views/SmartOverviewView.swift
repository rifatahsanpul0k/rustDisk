import SwiftUI

struct SmartOverviewView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    private var hasScannedAnyCategory: Bool {
        viewModel.categoryStatus.values.contains { $0.isCompleted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                sectionTitle("Category Scanners")
                cardsGrid
            }
            .padding(20)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.green)
                        Text("Quick Clean")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }

                    if hasScannedAnyCategory {
                        Text("Ready to safely free up")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Text(viewModel.recommendedReclaimGB)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                            .monospacedDigit()

                        Text("Leftover temporary app caches, old project builds, and installers you don't need anymore. Your personal photos, documents, and code are never touched.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("On-Demand Mac Storage Audit")
                            .font(.title2.bold())

                        Text("Scan only what you want, when you want. Run a fast scan across your temporary junk and old project folders in seconds without heating up your Mac.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Image(systemName: hasScannedAnyCategory ? "arrow.down.circle.fill" : "bolt.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green.gradient)
            }

            HStack(spacing: 12) {
                if hasScannedAnyCategory && viewModel.recommendedReclaimBytes > 0 {
                    Button {
                        viewModel.quickCleanSafeJunk()
                    } label: {
                        Label(
                            "Move Safe Junk to Trash (\(viewModel.recommendedReclaimGB))",
                            systemImage: "trash.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking || viewModel.isScanning)

                    Button {
                        viewModel.scanFastJunk()
                    } label: {
                        Label("Rescan Fast Junk", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking || viewModel.isScanning)
                } else {
                    Button {
                        viewModel.scanFastJunk()
                    } label: {
                        Label("Scan Fast Junk & Caches", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking || viewModel.isScanning)
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.green.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green.opacity(0.24), lineWidth: 1)
                }
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .padding(.top, 4)
    }

    private var cardsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            categoryCard(
                title: "Junk & Temp Files",
                icon: "trash.fill",
                color: .green,
                detail: "Leftover app and browsing cache files. Recreated automatically as needed.",
                tab: .safeCaches
            )

            categoryCard(
                title: "Old Coding Folders",
                icon: "hammer.fill",
                color: .orange,
                detail: "Heavy dependency folders untouched for 30+ days. Code stays completely safe.",
                tab: .projects
            )

            categoryCard(
                title: "Big Files",
                icon: "externaldrive.fill",
                color: .blue,
                detail: "Large disk image installers, video files, and archives taking up room.",
                tab: .largeFiles
            )

            categoryCard(
                title: "Twin Files",
                icon: "square.on.square",
                color: .purple,
                detail: "Exact copies of files or folders. One original copy is always kept safe.",
                tab: .duplicates
            )

            categoryCard(
                title: "Apps & Dev Tools",
                icon: "shippingbox.fill",
                color: .teal,
                detail: "Command-line packages, runtimes, and Docker virtual machine disks.",
                tab: .packages
            )
        }
    }

    private func categoryCard(
        title: String,
        icon: String,
        color: Color,
        detail: String,
        tab: NavigationTab
    ) -> some View {
        let status = viewModel.status(for: tab)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.headline)
                Text(title)
                    .font(.headline)
                Spacer()

                switch status {
                case .notScanned:
                    Text("Ready")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())

                case .scanning:
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Scanning…")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(color)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())

                case .completed(let count, let bytes, _):
                    Text(viewModel.byteCount(bytes))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(count > 0 ? color : .secondary)
                        .monospacedDigit()

                case .cancelled:
                    Text("Stopped")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                switch status {
                case .notScanned:
                    Button {
                        viewModel.scanCategory(tab)
                    } label: {
                        Label("Scan \(title)", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                    .disabled(viewModel.isWorking)

                case .scanning:
                    Button(role: .cancel) {
                        viewModel.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                case .completed(let count, _, _):
                    Button {
                        viewModel.selectedTab = tab
                    } label: {
                        HStack(spacing: 4) {
                            Text(count > 0 ? "Inspect (\(count))" : "Inspect")
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(count > 0 ? color : .secondary)

                    Button {
                        viewModel.scanCategory(tab)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Rescan \(title)")
                    .disabled(viewModel.isWorking)

                case .cancelled:
                    Button {
                        viewModel.scanCategory(tab)
                    } label: {
                        Label("Scan Again", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                    .disabled(viewModel.isWorking)
                }
            }
        }
        .padding(16)
        .frame(minHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color.opacity(status.isScanning ? 0.45 : 0.16), lineWidth: status.isScanning ? 2 : 1)
                }
        )
    }
}
