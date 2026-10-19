import Foundation

/// Centralized accessor for all user-facing strings shipped in
/// `Resources/Localizable.xcstrings`. Keeps lookups out of UI sites and
/// gives a single place to add new copy.
enum SDKStrings {
    static var errorTitle: String {
        localized("error.title")
    }

    static var errorOffline: String {
        localized("error.offline")
    }

    static var errorTimeout: String {
        localized("error.timeout")
    }

    static var errorServer: String {
        localized("error.server")
    }

    static var errorRateLimited: String {
        localized("error.rate_limited")
    }

    static var errorConfig: String {
        localized("error.config")
    }

    static var errorDetailsShow: String {
        localized("error.details.show")
    }

    static var errorDetailsHide: String {
        localized("error.details.hide")
    }

    static var validationDescriptionRequired: String {
        localized("validation.description.required")
    }

    static var validationDescriptionTooLong: String {
        localized("validation.description.too_long")
    }

    static var validationTooManyScreenshots: String {
        localized("validation.too_many_screenshots")
    }

    static var validationFileTooLarge: String {
        localized("validation.file_too_large")
    }

    static var successTitle: String {
        localized("success.title")
    }

    static var successMessage: String {
        localized("success.message")
    }

    static var successPartialTitle: String {
        localized("success.partial.title")
    }

    static var successPartialMessage: String {
        localized("success.partial.message")
    }

    static var discardDialogTitle: String {
        localized("discard.dialog.title")
    }

    static var discardDialogMessage: String {
        localized("discard.dialog.message")
    }

    static var discardDialogConfirm: String {
        localized("discard.dialog.confirm")
    }

    static var discardDialogKeep: String {
        localized("discard.dialog.keep")
    }

    static var photosPermissionTitle: String {
        localized("photos.permission.title")
    }

    static var photosPermissionMessage: String {
        localized("photos.permission.message")
    }

    static var photosPermissionContinue: String {
        localized("photos.permission.continue")
    }

    static var photosPermissionNotNow: String {
        localized("photos.permission.not_now")
    }

    static var previewTitle: String {
        localized("preview.title")
    }

    static var previewClose: String {
        localized("preview.close")
    }

    static var previewDelete: String {
        localized("preview.delete")
    }

    static func previewOpen(_ attachmentNumber: Int) -> String {
        String(format: localized("preview.open"), attachmentNumber)
    }

    /// "N of M" attachment counter shown in the preview's top chrome.
    static func previewCounter(_ current: Int, _ total: Int) -> String {
        String(format: localized("preview.counter"), current, total)
    }

    static var markupOpen: String {
        localized("markup.open")
    }

    static var markupTitle: String {
        localized("markup.title")
    }

    static var markupCancel: String {
        localized("markup.cancel")
    }

    static var markupDone: String {
        localized("markup.done")
    }

    static var markupUndo: String {
        localized("markup.undo")
    }

    static var markupToolBox: String {
        localized("markup.tool.box")
    }

    static var markupToolArrow: String {
        localized("markup.tool.arrow")
    }

    static var markupToolPen: String {
        localized("markup.tool.pen")
    }

    static var markupToolRedact: String {
        localized("markup.tool.redact")
    }

    static var markupRedactBlur: String {
        localized("markup.redact.blur")
    }

    static var markupRedactSolid: String {
        localized("markup.redact.solid")
    }

    static var markupInk: String {
        localized("markup.ink")
    }

    static func videoDuration(_ seconds: Int) -> String {
        String(format: localized("video.duration"), seconds)
    }

    static func videoPreview(_ index: Int, _ seconds: Int) -> String {
        String(format: localized("video.preview"), index, seconds)
    }

    static var videoPlay: String {
        localized("video.play")
    }

    static var attachmentProcessing: String {
        localized("attachment.processing")
    }

    static var videoPause: String {
        localized("video.pause")
    }

    static var videoSeek: String {
        localized("video.seek")
    }

    static func videoFailure(_ reason: String) -> String {
        localized("video.failure.\(reason)")
    }

    static func videoDurationExceeded(_ actual: Double, limit: Double) -> String {
        String(format: localized("video.failure.tooLong"), actual, limit)
    }

    static func videoSizeExceeded(_ actual: Int64, limit: Int64) -> String {
        String(format: localized("video.failure.tooLarge"), Double(actual) / 1_000_000, actual, Double(limit) / 1_000_000, limit)
    }

    static var videoInvalid: String {
        localized("video.invalid")
    }

    static var videoLimits: String {
        localized("video.limits")
    }

    static var videoUnavailable: String {
        localized("video.unavailable")
    }

    private static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: BugScreenResources.bundle)
    }
}
