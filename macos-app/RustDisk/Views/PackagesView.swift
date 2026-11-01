import AppKit
import SwiftUI

enum PackageManagerFilter: String, CaseIterable, Identifiable {
    case all = "All Tools"
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
            headerBanner
            toolbar
            PackageSummaryMetricStrip()
            Divider()

            List(selection: $viewModel.selectedIDs) {
                ForEach(filteredPackages, id: \.id) { package in
                    PackageRow(package: package)
                        .tag(package.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                switch viewModel.status(for: .packages) {
                case .notScanned:
                    VStack(spacing: 14) {
                        EmptyStateView(
                            title: "Apps & Dev Tools Not Scanned Yet",
                            systemImage: "shippingbox.fill",
                            message: "Scan your Mac to check Homebrew packages, Python environments, Node versions, and Docker virtual disks."
                        )
                        Button {
                            viewModel.scanCategory(.packages)
                        } label: {
                            Label("Scan Apps & Dev Tools", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .controlSize(.large)
                        .disabled(viewModel.isWorking)
                    }

                case .scanning:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Auditing Developer Tools…")
                            .font(.headline)
                        Text("Querying package receipts and checking virtual disk allocations.")
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
                    if viewModel.terminalPackages.isEmpty {
                        VStack(spacing: 12) {
                            EmptyStateView(
                                title: "No developer packages found",
                                systemImage: "checkmark.seal.fill",
                                message: "No CLI packages or virtual disks detected in standard locations."
                            )
                            Button {
                                viewModel.scanCategory(.packages)
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if filteredPackages.isEmpty {
                        EmptyStateView(
                            title: "No matching packages",
                            systemImage: "line.3.horizontal.decrease.circle",
                            message: "Try clearing your search query or switching managers."
                        )
                    }

                case .cancelled:
                    VStack(spacing: 12) {
                        EmptyStateView(
                            title: "Scan Stopped",
                            systemImage: "xmark.circle",
                            message: "The scan was stopped. Existing tools were kept."
                        )
                        Button {
                            viewModel.scanCategory(.packages)
                        } label: {
                            Label("Scan Apps & Tools", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                    }
                }
            }
        }
    }

    private var headerBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps & Dev Tools")
                    .font(.title2.bold())
                Text("Extra coding tools and virtual machines installed on your Mac.")
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
                TextField("Search apps & tools…", text: $searchText)
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

            Picker("Manager", selection: $managerFilter) {
                ForEach(PackageManagerFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            Menu {
                Toggle("Explicitly Installed Only", isOn: $explicitOnly)
                Toggle("Multi-Version / Bloat Only", isOn: $multiVersionOnly)
                Divider()
                Button("Clean Homebrew Cache") {
                    viewModel.requestMaintenance("brew_cleanup")
                }
                .disabled(viewModel.isWorking)
                Button("Remove Unused Homebrew Packages") {
                    viewModel.requestMaintenance("brew_autoremove")
                }
                .disabled(viewModel.isWorking)
                Button("Prune Docker VM") {
                    viewModel.requestMaintenance("docker_prune")
                }
                .disabled(viewModel.isWorking)
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if viewModel.activeScanningCategory == .packages {
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    viewModel.scanCategory(.packages)
                } label: {
                    Label(
                        viewModel.status(for: .packages).isCompleted ? "Refresh" : "Scan",
                        systemImage: viewModel.status(for: .packages).isCompleted ? "arrow.clockwise" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan Apps & Dev Tools (Cmd + R)")
            }

            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct PackageSummaryMetricStrip: View {
    @EnvironmentObject private var viewModel: DiskAuditViewModel

    private var totalBytes: UInt64 {
        viewModel.terminalPackages.reduce(0) { $0.saturatingAdding($1.physicalBytes) }
    }

    private var multiVersionCount: Int {
        viewModel.terminalPackages.filter { $0.versionCount > 1 }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            metric("Total Tools", "\(viewModel.terminalPackages.count)", .secondary)
            metric("Space Occupied", viewModel.byteCount(totalBytes), .blue)
            metric("Multi-Version Tools", "\(multiVersionCount)", multiVersionCount > 0 ? .orange : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PackageRow: View {
    let package: TerminalPackage
    @EnvironmentObject private var viewModel: DiskAuditViewModel
    @State private var showingInfo = false

    private var shortPath: String {
        let home = viewModel.homeDirectory
        return package.path.hasPrefix(home) ? "~" + package.path.dropFirst(home.count) : package.path
    }

    private var isContainer: Bool {
        package.manager == "Container VM"
    }

    var body: some View {
        HStack(spacing: 12) {
            // ELEMENT 1: Left (Icon + Bold Friendly Title + 1-Line Subtitle)
            Image(systemName: isContainer ? "desktopcomputer" : "shippingbox.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isContainer ? Color.purple : Color.blue)
                .frame(width: 30, height: 30)
                .background((isContainer ? Color.purple : Color.blue).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(package.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            // ELEMENT 2: Middle/Right (ONE Semantic Safety Pill)
            Text(isContainer ? "Keep Safe" : "Can Be Rebuilt")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isContainer ? Color.secondary : Color.blue).opacity(0.12))
                .foregroundStyle(isContainer ? Color.secondary : Color.blue)
                .clipShape(Capsule())
                .lineLimit(1)

            // ELEMENT 3: Far Right (Formatted Size + ⓘ Button + Uninstall)
            HStack(spacing: 8) {
                Text(viewModel.byteCount(package.physicalBytes))
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
                    packageInfoPopover
                }

                Button(isContainer ? "Prune" : "Uninstall") {
                    viewModel.requestPackageAction(package)
                }
                .buttonStyle(.bordered)
                .tint(isContainer ? .orange : .red)
                .disabled(viewModel.isWorking)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button(isContainer ? "Prune via CLI" : "Uninstall via CLI", systemImage: "terminal") {
                viewModel.requestPackageAction(package)
            }
            Button("Reveal in Finder", systemImage: "folder") {
                FinderSupport.reveal(path: package.path)
            }
            Divider()
            Button("Copy Uninstall Command", systemImage: "terminal") {
                Clipboard.copy(package.uninstallCmd)
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                Clipboard.copy(package.path)
            }
        }
    }

    private var subtitleText: String {
        if viewModel.showProDetails {
            return "\(shortPath) · \(package.uninstallCmd)"
        }
        if isContainer {
            return "Docker virtual disk · Manage with Docker Prune"
        }
        if package.versionCount > 1 {
            return "\(package.manager) · \(package.versionCount) versions installed"
        }
        return "\(package.manager) · Installed developer tool"
    }

    private var packageInfoPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isContainer ? "desktopcomputer" : "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(isContainer ? Color.purple : Color.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(package.manager) · \(package.installedOnRequest ? "User Installed" : "Dependency")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Safety Status", value: isContainer ? "Protected Container Disk (Use Docker Prune)" : "Can Be Rebuilt (Reinstallable via CLI)")
                infoRow(label: "Physical APFS Size", value: viewModel.byteCount(package.physicalBytes))
                if package.logicalBytes != package.physicalBytes {
                    infoRow(label: "Logical Size", value: viewModel.byteCount(package.logicalBytes))
                }
                if package.versionCount > 1 {
                    infoRow(label: "Versions Installed", value: "\(package.versionCount) versions")
                }
                infoRow(label: "CLI Command", value: package.uninstallCmd)
                infoRow(label: "Location", value: shortPath)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Show in Finder", systemImage: "folder") {
                    FinderSupport.reveal(path: package.path)
                    showingInfo = false
                }
                .buttonStyle(.bordered)

                Button("Copy Command", systemImage: "terminal") {
                    Clipboard.copy(package.uninstallCmd)
                }
                .buttonStyle(.bordered)

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
}
