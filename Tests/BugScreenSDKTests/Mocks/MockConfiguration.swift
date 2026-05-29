@testable import BugScreenSDK
import Foundation
import UIKit

/// Test utilities for BugScreen SDK unit tests.
///
/// Provides helper methods and constants for testing SDK functionality.
enum TestHelpers {
    /// Valid test API key
    static let validAPIKey = "fb_test_api_key_1234567890"

    /// Invalid API key (too short)
    static let shortAPIKey = "fb_short"

    /// Empty API key
    static let emptyAPIKey = ""

    /// Resets the SDK to unconfigured state (for testing multiple configurations).
    ///
    /// Note: This is a workaround since BugScreenSDK is a singleton.
    /// In production code, you should only configure once.
    @MainActor
    static func resetSDK() {
        BugScreenSDK.shutdown()
    }

    /// Creates sample custom metadata for testing
    static let sampleCustomData: [String: String] = [
        "userId": "12345",
        "screen": "TestView",
        "featureFlag": "enabled",
    ]

    /// Renders a small solid-colour image. Used by tests that need a real
    /// `UIImage` payload (multipart screenshot encoding, auto-attach flow).
    static func solidImage(
        width: Int = 4,
        height: Int = 4,
        color: UIColor = .red
    ) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Renders an image with a specific pixel size and scale, mimicking a
    /// real device screenshot (e.g. 1179×2556 px at scale 3). Use this when
    /// the test cares about pixel-vs-point distinctions — `solidImage`'s
    /// renderer defaults to `UIScreen.main.scale`, which varies by simulator.
    static func retinaImage(
        pixelWidth: Int,
        pixelHeight: Int,
        scale: CGFloat,
        color: UIColor = .blue
    ) -> UIImage {
        let pointSize = CGSize(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: pointSize))
        }
    }
}
