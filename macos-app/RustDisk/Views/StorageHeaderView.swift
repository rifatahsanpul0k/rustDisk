import SwiftUI

struct StorageHeaderView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("APFS Storage", systemImage: "internaldrive.fill")
                    .font(.headline)

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

                HStack(spacing: 1) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.72))
                        .frame(width: max(remainingWidth, 0))
                    Rectangle()
                        .fill(Color.green.opacity(0.95))
                        .frame(width: max(selectedWidth, 0))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: max(freeWidth, 0))
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            }
            .frame(height: 12)

            HStack(spacing: 16) {
                legend(color: .blue, title: "Used after selection", value: viewModel.byteCount((viewModel.diskOverview?.usedBytes ?? 0).saturatingSubtracting(viewModel.selectedPhysicalBytes)))
                legend(color: .green, title: "Selected to reclaim", value: viewModel.selectedPhysicalGB)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Free now \(viewModel.byteCount(viewModel.diskOverview?.availableBytes ?? 0))")
                    Text("Free after cleanup: \(viewModel.byteCount(viewModel.projectedAvailableBytes))")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func legend(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
