import UIKit

@MainActor
enum WindowSnapshot {
    static func capture(_ window: UIWindow, maxDimension: CGFloat = 1920) -> UIImage? {
        guard !window.isHidden, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, maxDimension / max(window.bounds.width, window.bounds.height))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        // Layer rendering also works for SwiftUI windows that defer drawHierarchy commits.
        return renderer.image { window.layer.render(in: $0.cgContext) }
    }
}
