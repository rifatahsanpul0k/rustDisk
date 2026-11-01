import SwiftUI

struct SummaryMetricStrip: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    let items: [ScannedItem]
    let recommendedItems: [ScannedItem]

    private var selectedBytes: UInt64 {
        let selectedIDs = viewModel.selectedIDs
        return items
            .filter { selectedIDs.contains($0.id) && $0.risk != .highRiskCli }
            .reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    private var foundBytes: UInt64 {
        items.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    private var recommendedBytes: UInt64 {
        recommendedItems.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    var body: some View {
        HStack(spacing: 10) {
            metric(title: "Total Found", value: viewModel.byteCount(foundBytes), color: .secondary)
            metric(title: "Selected to Reclaim", value: viewModel.byteCount(selectedBytes), color: .orange)
            metric(title: "Safe Recommended", value: viewModel.byteCount(recommendedBytes), color: .green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }

    private func metric(title: String, value: String, color: Color) -> some View {
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
}
