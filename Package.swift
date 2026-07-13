// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BugScreenSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "BugScreenSDK",
            targets: ["BugScreenSDK"]
        ),
        // No-op stub with an identical public API but empty bodies. Consumers
        // pair it with BugScreenSDK per build configuration (CocoaPods
        // `:configurations`) to keep BugScreen out of production builds. See
        // docs/product/.../DX-009. Parity is enforced by check-noop-parity.sh.
        .library(
            name: "BugScreenSDKNoOp",
            targets: ["BugScreenSDKNoOp"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "BugScreenSDK",
            dependencies: [],
            path: "Sources/BugScreenSDK",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "BugScreenSDKNoOp",
            dependencies: [],
            path: "Sources/BugScreenSDKNoOp"
        ),
        .testTarget(
            name: "BugScreenSDKTests",
            dependencies: ["BugScreenSDK"],
            path: "Tests/BugScreenSDKTests"
        ),
        .testTarget(
            name: "BugScreenSDKNoOpTests",
            // Depends on both modules so NoOpValueParityTests can assert the
            // stub's value-type *bodies* (displayName, CodingKeys) still match
            // the real SDK — the symbol-graph parity check locks only signatures.
            dependencies: ["BugScreenSDKNoOp", "BugScreenSDK"],
            path: "Tests/BugScreenSDKNoOpTests"
        ),
    ]
)
