import AppKit
import SwiftUI

enum PackageManagerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case homebrewFormula = "Homebrew Formula"
    case homebrewCask = "Homebrew Cask"
    case pythonConda = "Python & Conda"
    case nodeJS = "Node & JS"
    case rustToolchain = "Rust Toolchain"
    case containerVM = "Container VM"

    var id: String { rawValue }
}

struct PackagesView: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var searchText = ""
    @State private var managerFilter: PackageManagerFilter = .all
    @State private var explicitOnly = false
    @State private var multiVersionOnly = false

    private var filteredPackages: [TerminalPackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.terminalPackages.filter { package in
            let managerMatches = managerFilter == .all || package.manager == managerFilter.rawValue
            let explicitMatches = !explicitOnly || package.installedOnRequest
            let bloatMatches = !multiVersionOnly || package.versionCount > 1 || package.manager == "Container VM"
            let searchMatches = query.isEmpty
                || package.name.lowercased().contains(query)
                || package.manager.lowercased().contains(query)
                || package.path.lowercased().contains(query)
                || package.uninstallCmd.lowercased().contains(query)
            return managerMatches && explicitMatches && bloatMatches && searchMatches
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            PackageSummaryMetricStrip()
            Divider()
            maintenanceBar
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(filteredPackages, id: \.id) { package in
                    PackageRow(package: package)
                        .tag(package.id)
                }
            }
            .overlay {
                if viewModel.terminalPackages.isEmpty {
                    EmptyStateView(
                        title: "No terminal packages found",
                        systemImage: "terminal",
                        message: "RustDisk checks Homebrew, Python/Conda, Node, Rust toolchains, and container virtual disks."
                    )
                } else if filteredPackages.isEmpty {
                    EmptyStateView(
                        title: "No matching packages",
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: "Try another manager, package name, path, or filter toggle."
                    )
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Label("Terminal Packages", systemImage: "terminal.fill")
                    .font(.headline)
                Text("CLI tools and runtimes installed outside the macOS Applications folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextField("Search name, manager, path, or command", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
                Spacer()
                Toggle("Explicitly Installed Only", isOn: $explicitOnly)
                    .toggleStyle(.checkbox)
                Toggle("Multi-Version / Bloat Only", isOn: $multiVersionOnly)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Text("Manager")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Manager", selection: $managerFilter) {
                    ForEach(PackageManagerFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(12)
    }

    private var maintenanceBar: some View {
        HStack(spacing: 10) {
            Text("Maintenance")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Brew Cleanup") {
                viewModel.requestMaintenance("brew_cleanup")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking)
            Button("Brew Autoremove") {
                viewModel.requestMaintenance("brew_autoremove")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking)
            Button("Prune Docker") {
                viewModel.requestMaintenance("docker_prune")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(viewModel.isWorking)
            Spacer()
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Running CLI…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct PackageSummaryMetricStrip: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    private var totalBytes: UInt64 {
        viewModel.terminalPackages.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    private var selectedBytes: UInt64 {
        viewModel.terminalPackages
            .filter { viewModel.selectedIDs.contains($0.id) }
            .reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    var body: some View {
        HStack(spacing: 10) {
            metric("Total Found", viewModel.byteCount(totalBytes), .secondary)
            metric("Selected to Reclaim", viewModel.byteCount(selectedBytes), .orange)
            metric("Safe Recommended", "Review before action", .purple)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
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

private struct PackageRow: View {
    let package: TerminalPackage
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingDetails = false

    private var isSparse: Bool {
        package.logicalBytes > package.physicalBytes.saturatingMultiplying(2)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.manager == "Container VM" ? "shippingbox.fill" : "terminal.fill")
                .foregroundStyle(package.manager == "Container VM" ? .orange : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.headline)
                    badge(package.manager, color: .blue)
                    if package.manager == "Homebrew Formula" {
                        badge(package.installedOnRequest ? "User Installed" : "Dependency", color: package.installedOnRequest ? .green : .orange)
                    }
                    if package.versionCount > 1 {
                        badge("\(package.versionCount) versions", color: .orange)
                    }
                    badge(riskLabel, color: riskColor)
                }
                Text("CLI-managed tool or runtime footprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isSparse {
                    Text("Sparse: \(viewModel.byteCount(package.physicalBytes)) physical / \(viewModel.byteCount(package.logicalBytes)) logical")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(package.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                DisclosureGroup("Technical details", isExpanded: $showingDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(package.uninstallCmd)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 3)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.byteCount(package.physicalBytes))
                    .font(.system(.body, design: .monospaced))
                    .bold()
                Text("physical")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(package.manager == "Container VM" ? "Prune via CLI" : "Uninstall") {
                viewModel.requestPackageAction(package)
            }
            .buttonStyle(.bordered)
            .tint(package.manager == "Container VM" ? .orange : .red)
            .disabled(viewModel.isWorking)

            Button {
                reveal(package.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Menu {
                packageActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 5)
        .contextMenu {
            packageActions
        }
    }

    @ViewBuilder
    private var packageActions: some View {
        Button(package.manager == "Container VM" ? "Prune via CLI" : "Uninstall via CLI", systemImage: "terminal") {
            viewModel.requestPackageAction(package)
        }
        Button("Reveal in Finder", systemImage: "folder") {
            reveal(package.path)
        }
        Button("Copy CLI Command", systemImage: "doc.on.doc") {
            copy(package.uninstallCmd)
        }
        Button("Copy Path", systemImage: "link") {
            copy(package.path)
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

    private var riskLabel: String {
        switch package.risk {
        case .safe: return "Safe"
        case .rebuildable: return "Rebuildable"
        case .highRiskCli: return "High-Risk CLI / Protected"
        }
    }

    private var riskColor: Color {
        switch package.risk {
        case .safe: return .green
        case .rebuildable: return .orange
        case .highRiskCli: return .red
        }
    }

    private func reveal(_ path: String) {
        FinderSupport.reveal(path: path)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        addingReportingOverflow(other).partialValue
    }

    func saturatingMultiplying(_ other: UInt64) -> UInt64 {
        multipliedReportingOverflow(by: other).partialValue
    }
}
