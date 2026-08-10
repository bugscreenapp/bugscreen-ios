import Foundation

/// The bundle that holds the reporter's packaged resources (localizations, the
/// wordmark asset catalog).
///
/// Resolves three ways, which is why the lookup is not just `.module`: `Bundle.module`
/// under SwiftPM, the CocoaPods-generated `BugScreenSDK.bundle` sub-bundle otherwise, and
/// — when the companion app compiles this directory into its own target (RFC-003 §2.5) —
/// its main bundle, which the `container` fallback below lands on when no sub-bundle
/// exists.
///
/// The CocoaPods name below **must** match `s.resource_bundles`' key in
/// `BugScreenSDK.podspec`. A mismatch fails silently — strings fall back to the key and
/// the wordmark simply does not render, on the CocoaPods channel only, which CI's SPM
/// build cannot see. `testResourceBundleNameMatchesPodspec` asserts the pair.
///
/// Both the strings and the asset catalog ship via the podspec's `s.resource_bundles`
/// (a sub-bundle), never `s.resources` into the consumer `.app` root — see the
/// "CocoaPods `s.resources` ships a same-named file into the consumer `.app` root"
/// postmortem. Always load packaged resources through this bundle, not `.module`
/// directly, so the CocoaPods build resolves them too.
enum BugScreenResources {
    /// The `s.resource_bundles` key the podspec must use. Read by the podspec test.
    static let cocoaPodsBundleName = "BugScreenSDK"

    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
            return .module
        #else
            let container = Bundle(for: BundleToken.self)
            if let url = container.url(forResource: cocoaPodsBundleName, withExtension: "bundle"),
               let bundle = Bundle(url: url)
            {
                return bundle
            }
            return container
        #endif
    }()

    private final class BundleToken {}
}
