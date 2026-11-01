// swift-tools-version: 5.9
import Foundation
import PackageDescription

// `scripts/build_rust_bridge.sh` stages the Rust static archive here. It is
// linked by explicit file path, so the linker can never fall back to a dynamic
// library and nothing in the final binary points at the Rust build directory.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustStaticLibrary = "\(packageDirectory)/lib/librustdisk_core.a"

let package = Package(
    name: "RustDisk",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "RustDisk", targets: ["RustDisk"]),
    ],
    targets: [
        // A system-library target cannot carry linker settings, so the static
        // archive is attached to the executable that imports this module.
        .systemLibrary(
            name: "rustdisk_coreFFI",
            path: "RustDiskCoreFFI"
        ),
        .executableTarget(
            name: "RustDisk",
            dependencies: ["rustdisk_coreFFI"],
            path: "RustDisk",
            linkerSettings: [
                // System dependencies of the Rust static library
                // (`cargo rustc -- --print native-static-libs`).
                .linkedLibrary("iconv"),
                .linkedLibrary("objc"),
                .linkedFramework("Foundation"),
                // SwiftPM has no safe API for linking a local archive by path.
                .unsafeFlags(["-Xlinker", rustStaticLibrary]),
            ]
        )
    ]
)
