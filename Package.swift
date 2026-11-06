// swift-tools-version: 6.2
import PackageDescription

// No third-party dependencies, on purpose: everything that talks to the
// headphones is in this repository and readable.
let package = Package(
    name: "Hush",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure protocol logic: framing, commands, parsing, and the session
        // state machine. No Bluetooth, no UI, fully unit tested.
        .target(name: "HushCore"),

        // The menu bar app: IOBluetooth link, controller, SwiftUI panel.
        .executableTarget(
            name: "Hush",
            dependencies: ["HushCore"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),

        // Debug CLI. Talks to a running Hush (started with -DebugControl YES)
        // over local distributed notifications. No Bluetooth of its own.
        .executableTarget(name: "hushctl"),

        .testTarget(name: "HushCoreTests", dependencies: ["HushCore"]),
    ]
)
