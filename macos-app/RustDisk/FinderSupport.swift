import AppKit

enum FinderSupport {
    static func reveal(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        var targetURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let fileManager = FileManager.default

        // If a scan result disappeared after the scan, reveal the nearest
        // existing parent instead of silently doing nothing.
        while !fileManager.fileExists(atPath: targetURL.path) {
            let parentURL = targetURL.deletingLastPathComponent()
            guard parentURL.path != targetURL.path else { return }
            targetURL = parentURL
        }

        NSApp.activate(ignoringOtherApps: true)
        if !NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "") {
            NSWorkspace.shared.open(targetURL)
        }
    }
}

extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }

    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
