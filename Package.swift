// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LensBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LensBarCore", targets: ["LensBar"]),
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
        .target(
            name: "LensBar",
            dependencies: ["IOKitUSB"],
            path: "Sources/LensBar",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .testTarget(
            name: "LensBarTests",
            dependencies: ["LensBar"],
            path: "Tests/LensBarTests"
        ),
    ]
)
