import SwiftUI

struct ScannedItemRow: View {
    let item: ScannedItem
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingDetails = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        badge(item.category, color: .blue)
                        badge(riskLabel, color: tint)
                    }
                    Text(humanSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(viewModel.naturalAge(item.daysSinceModified))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(viewModel.byteCount(item.physicalBytes))
                    .font(.system(.body, design: .monospaced))
                    .bold()
                    .frame(width: 96, alignment: .trailing)
            }

            DisclosureGroup("Technical details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Physical APFS: \(viewModel.byteCount(item.physicalBytes)) · Logical: \(viewModel.byteCount(item.logicalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .help("\(humanSubtitle)\nModified \(item.daysSinceModified) days ago\n\(item.path)")
    }

    private var humanSubtitle: String {
        switch item.category {
        case "macOS App Caches", "System & App Cache", "Web & Node Caches", "AI & Python Caches", "JVM & Build Caches", "Xcode & Homebrew Caches":
            return "Temporary app and package download files. Safe to remove; apps recreate them automatically."
        default:
            return shortPath
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

    private var iconName: String {
        switch item.risk {
        case .safe: return "checkmark.seal.fill"
        case .rebuildable: return "arrow.triangle.2.circlepath"
        case .highRiskCli: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.risk {
        case .safe: return .green
        case .rebuildable: return .orange
        case .highRiskCli: return .red
        }
    }

    private var riskLabel: String {
        switch item.risk {
        case .safe: return "Safe"
        case .rebuildable: return "Rebuildable"
        case .highRiskCli: return "Protected"
        }
    }
}
