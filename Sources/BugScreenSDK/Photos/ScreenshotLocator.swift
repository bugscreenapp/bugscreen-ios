import UIKit
import Photos
import OSLog

@available(iOS 15.0, *)
internal enum ScreenshotLocator {

    private static let logger = OSLog(subsystem: "com.bugscreen.sdk", category: "ScreenshotLocator")

    static func findLatestScreenshot(
        since: Date,
        within: TimeInterval = 5,
        completion: @escaping (UIImage?) -> Void
    ) {
        attempt(since: since, within: within) { image in
            if image != nil {
                completion(image)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                attempt(since: since, within: within, completion: completion)
            }
        }
    }

    private static func attempt(
        since: Date,
        within: TimeInterval,
        completion: @escaping (UIImage?) -> Void
    ) {
        let earliest = since.addingTimeInterval(-within)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0 AND creationDate >= %@",
            PHAssetMediaSubtype.photoScreenshot.rawValue,
            earliest as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1

        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = result.firstObject else {
            SDKLog.internalLog("No recent screenshot asset found", log: logger, type: .debug)
            completion(nil)
            return
        }

        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isNetworkAccessAllowed = false
        requestOptions.isSynchronous = false
        requestOptions.resizeMode = .none

        // PHImageManager calls the result handler at least once. With opportunistic delivery it
        // may call once with a degraded image and once more with the high-quality one. If the
        // asset is iCloud-only and isNetworkAccessAllowed = false, we'll never get the
        // high-quality call — info reports that via PHImageResultIsInCloudKey / PHImageErrorKey.
        // Track completion so the caller is always notified exactly once and the request can
        // be released.
        var didComplete = false
        let finish: (UIImage?) -> Void = { image in
            guard !didComplete else { return }
            didComplete = true
            DispatchQueue.main.async { completion(image) }
        }

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: requestOptions
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let hasError = info?[PHImageErrorKey] != nil

            if cancelled || hasError || (isDegraded && isInCloud) {
                finish(nil)
                return
            }
            if isDegraded { return }
            finish(image)
        }
    }
}
