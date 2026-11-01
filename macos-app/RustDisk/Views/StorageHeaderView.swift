import SwiftUI

struct StorageHeaderView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("Mac Storage", systemImage: "internaldrive.fill")
                    .font(.headline)

                if let thermalLabel = viewModel.thermalStateLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.teal)
                        Text(thermalLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.teal.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.teal.opacity(0.25), lineWidth: 1))
                    .help("Easing processor load to keep your Mac cool and silent.")
                }

                Spacer()

                if let overview = viewModel.diskOverview {
                    Text("Used \(viewModel.byteCount(overview.usedBytes)) of \(viewModel.byteCount(overview.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            GeometryReader { geometry in
                let total = max(viewModel.diskOverview?.totalBytes ?? 0, 1)
                let used = viewModel.diskOverview?.usedBytes ?? 0
                let selected = min(viewModel.selectedPhysicalBytes, used)
                let remainingUsed = used.saturatingSubtracting(selected)
                let free = viewModel.diskOverview?.availableBytes ?? 0
                let remainingWidth = geometry.size.width * CGFloat(remainingUsed) / CGFloat(total)
                let selectedWidth = geometry.size.width * CGFloat(selected) / CGFloat(total)
                let freeWidth = geometry.size.width * CGFloat(free) / CGFloat(total)

                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.85))
                        .frame(width: max(remainingWidth, 0))
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: max(selectedWidth, 0))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.20))
                        .frame(width: max(freeWidth, 0))
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            }
            .frame(height: 12)

            HStack(spacing: 16) {
                legend(color: .blue, title: "Used", value: viewModel.byteCount((viewModel.diskOverview?.usedBytes ?? 0).saturatingSubtracting(viewModel.selectedPhysicalBytes)))
                legend(color: .green, title: "Selected to Clean", value: viewModel.selectedPhysicalGB)
                legend(color: .secondary.opacity(0.5), title: "Free Now", value: viewModel.byteCount(viewModel.diskOverview?.availableBytes ?? 0))

                Spacer()

                HStack(spacing: 4) {
                    Text("Free After Cleaning:")
                        .foregroundStyle(.secondary)
                    Text(viewModel.byteCount(viewModel.projectedAvailableBytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
    }

    private func legend(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title): \(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
