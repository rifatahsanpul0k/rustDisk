import SwiftUI

struct SafetyGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("How RustDisk Protects Your Mac", systemImage: "checkmark.shield.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                    Text("Built with safety-first rules so you never lose personal files, code, or macOS stability.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guideCard(
                        title: "1. 100% Recoverable (Moved to Trash First)",
                        icon: "trash.circle.fill",
                        color: .blue,
                        text: "Cleaned items are sent straight to your macOS Trash by default. You can open Trash, right-click any item, and click 'Put Back' at any time to restore it exactly where it was."
                    )

                    guideCard(
                        title: "2. System Armor (Core Files Are Mathematically Locked)",
                        icon: "lock.shield.fill",
                        color: .green,
                        text: "The compiled Rust engine strictly blocks /System, /Library, /Applications, Desktop, Documents, Photos, and .git repositories. These vital locations can never be deleted under any circumstance."
                    )

                    guideCard(
                        title: "3. Safe vs. Rebuildable Files",
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .orange,
                        text: "Temporary app caches and web scratchpads are safe to clean anytime—apps recreate them automatically. Older project build folders (like node_modules or target) can be restored in seconds with 'npm install' or 'cargo build' when you code again."
                    )

                    guideCard(
                        title: "4. Twin Files (Always Keeps One Original)",
                        icon: "doc.on.doc.fill",
                        color: .purple,
                        text: "When exact duplicate files or folders are found, RustDisk automatically locks and preserves one safe original copy so you never lose data."
                    )
                }
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(width: 580, height: 520)
    }

    private func guideCard(title: String, icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                }
        )
    }
}
