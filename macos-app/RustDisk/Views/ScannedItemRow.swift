import AppKit
import SwiftUI

struct ScannedItemRow: View {
    let item: ScannedItem
    var customSubtitle: String? = nil
    var customPillText: String? = nil
    var customPillColor: Color? = nil
    var customIcon: String? = nil

    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingInfo = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
    }

    var body: some View {
        HStack(spacing: 12) {
            // ELEMENT 1: Left (Icon + Bold Friendly Title + 1-Line Subtitle)
            Image(systemName: customIcon ?? iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(pillColor)
                .frame(width: 30, height: 30)
                .background(pillColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(effectiveSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            // ELEMENT 2: Middle/Right (At most ONE semantic safety pill)
            safetyPill

            // ELEMENT 3: Far Right (Clean Formatted Size + ⓘ Info Button)
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
                    itemInfoSheet
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") {
                FinderSupport.reveal(path: item.path)
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                copy(item.path)
            }
            if !item.restoreHint.isEmpty {
                Button("Copy Rebuild Command", systemImage: "terminal") {
                    copy(item.restoreHint)
                }
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

    private var effectiveSubtitle: String {
        if viewModel.showProDetails {
            return shortPath
        }
        if let customSubtitle {
            return customSubtitle
        }
        switch item.category {
        case "macOS App Caches", "System & App Cache", "Web & Node Caches", "AI & Python Caches", "JVM & Build Caches", "Xcode & Homebrew Caches":
            return "Temporary app cache · Safe to remove"
        case "Disk Images & Installers":
            return "Downloaded installer · Safe to remove"
        case "Archives & Backups":
            return "Compressed archive · Untouched \(viewModel.naturalAge(item.daysSinceModified))"
        case "Video & Audio Media":
            return "Media file · Untouched \(viewModel.naturalAge(item.daysSinceModified))"
        case "Virtual Machines & Disks":
            return "Virtual machine disk · Managed via tools"
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
        if let customPillText, let customPillColor {
            return (customPillText, customPillColor)
        }
        switch item.risk {
        case .safe:
            return ("Safe to Clean", .green)
        case .rebuildable:
            return ("Can Be Rebuilt", .orange)
        case .highRiskCli:
            return ("Keep Safe", .secondary)
        }
    }

    private var pillColor: Color {
        pillDetails.1
    }

    private var iconName: String {
        switch item.risk {
        case .safe:
            return "sparkles"
        case .rebuildable:
            return "arrow.triangle.2.circlepath"
        case .highRiskCli:
            return "lock.shield.fill"
        }
    }

    private var itemInfoSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: customIcon ?? iconName)
                    .font(.title2)
                    .foregroundStyle(pillColor)

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
                if !item.restoreHint.isEmpty {
                    infoRow(label: "Rebuild Command", value: item.restoreHint)
                }
                infoRow(label: "Location", value: shortPath)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Show in Finder", systemImage: "folder") {
                    FinderSupport.reveal(path: item.path)
                    showingInfo = false
                }
                .buttonStyle(.bordered)

                Button("Copy Path", systemImage: "doc.on.doc") {
                    copy(item.path)
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
