// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LensBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LensBarCore", targets: ["LensBarCore"]),
        // Shared by the app and the sandboxed LensBarCamera system extension.
        .library(name: "VirtualCameraKit", targets: ["VirtualCameraKit"]),
    ],
    targets: [
        // Thin ObjC wrapper around IOUSBHost.framework for UVC control transfers.
        // Kept as a separate target so Swift doesn't need unsafe bridging headers.
        .target(
            name: "IOKitUSB",
            path: "Sources/IOKitUSB",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Virtual-camera constants and pure logic: device/stream UIDs, custom
        // property names, format codec, format-update policy, rate estimator.
        // Foundation only, no IOKit, so the sandboxed extension can link it.
        .target(
            name: "VirtualCameraKit",
            path: "Sources/VirtualCameraKit"
        ),
        .target(
            name: "LensBarCore",
            dependencies: ["IOKitUSB", "VirtualCameraKit"],
            path: "Sources/LensBar",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .testTarget(
            name: "LensBarTests",
            dependencies: ["LensBarCore"],
            path: "Tests/LensBarTests"
        ),
        .testTarget(
            name: "VirtualCameraKitTests",
            dependencies: ["VirtualCameraKit"],
            path: "Tests/VirtualCameraKitTests"
        ),
    ]
)
