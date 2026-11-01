import SwiftUI

struct SafetyGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Safety & APFS Guide", systemImage: "questionmark.circle.fill")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    guideSection(
                        title: "Physical vs. Logical Space",
                        icon: "chart.bar.xaxis",
                        text: "RustDisk measures the APFS blocks actually allocated on your SSD. A sparse file such as Docker.raw can have a very large logical size while consuming far fewer physical blocks. The app shows both values so you can make decisions based on real reclaimable storage."
                    )
                    guideSection(
                        title: "The Three Safety Tiers",
                        icon: "shield.lefthalf.filled",
                        text: "Safe items are temporary caches, installers, and other low-risk files. Rebuildable items are project dependencies and runtimes that can be restored with a package install or build command. High-risk CLI or Protected items, such as Docker virtual disks and package dependencies, require an explicit CLI workflow and are never silently deleted."
                    )
                    guideSection(
                        title: "System Armor Guarantee",
                        icon: "lock.shield.fill",
                        text: "The Rust cleaner rejects relative paths, the filesystem root, /System, /bin, /sbin, /usr, /Applications, all of /Library, everything in /opt except /opt/homebrew, home folders themselves, .git, .ssh, .gnupg, .aws, and Docker.raw. It resolves symlinks and ignores letter case before checking. Source files are not targeted by project-artifact cleanup; only recognized dependency and build folders are offered."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 620, height: 500)
    }

    private func guideSection(title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
