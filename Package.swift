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
    dependencies: [
        // Test-only. Inspects the SwiftUI view tree from XCTest so BugReportView
        // gets view-layer coverage without XCUITest / on-device UI automation.
        // Wired only into BugScreenSDKTests, so consumers of the library product
        // never resolve it.
        .package(url: "https://github.com/nalexn/ViewInspector", exact: "0.10.3"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "BugScreenSDK",
            dependencies: [],
            path: "Sources/BugScreenSDK",
            resources: [
                // Two roots rather than one. Reporter/ is the directory the companion app
                // compiles into its own target (RFC-003 §2.5), so its strings catalogue and
                // asset catalogue have to travel with its code. PrivacyInfo.xcprivacy stays
                // out of it deliberately: it declares the boot-time API *this* target makes,
                // which is not the companion's to claim.
                .process("Resources"),
                .process("Reporter/Resources")
            ]
        ),
        .target(
            name: "BugScreenSDKNoOp",
            dependencies: [],
            path: "Sources/BugScreenSDKNoOp"
        ),
        .testTarget(
            name: "BugScreenSDKTests",
            dependencies: [
                "BugScreenSDK",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/BugScreenSDKTests"
        ),
        // The reporter's own tests. A separate bundle from BugScreenSDKTests even though
        // both now `@testable import BugScreenSDK`, because the reporter is a distinct
        // area with its own fixtures — and because each bundle keeps its own TestHelpers.
        .testTarget(
            name: "BugScreenSDKReporterTests",
            dependencies: [
                "BugScreenSDK",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/BugScreenSDKReporterTests"
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
