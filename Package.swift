// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeilLock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VeilLock", targets: ["VeilLock"])
    ],
    targets: [
        .target(name: "VeilLockCore"),
        .executableTarget(
            name: "VeilLock",
            dependencies: ["VeilLockCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "VeilLockCoreTests", dependencies: ["VeilLockCore"])
    ]
)
