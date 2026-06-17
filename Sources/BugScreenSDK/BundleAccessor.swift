import Foundation

/// The bundle that holds the SDK's packaged resources (localizations, the
/// wordmark asset catalog).
///
/// Resolves to `Bundle.module` under SwiftPM and to the CocoaPods-generated
/// `BugScreenSDK.bundle` sub-bundle otherwise. Both the strings and the asset
/// catalog ship via the podspec's `s.resource_bundles` (a sub-bundle), never
/// `s.resources` into the consumer `.app` root — see the "CocoaPods
/// `s.resources` ships a same-named file into the consumer `.app` root"
/// postmortem. Always load packaged resources through this bundle, not
/// `.module` directly, so the CocoaPods build resolves them too.
enum BugScreenResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
            return .module
        #else
            let container = Bundle(for: BundleToken.self)
            if let url = container.url(forResource: "BugScreenSDK", withExtension: "bundle"),
               let bundle = Bundle(url: url)
            {
                return bundle
            }
            return container
        #endif
    }()

    private final class BundleToken {}
}
